import Foundation
import Testing
@testable import FlareJobMonitor

@Suite("Model download")
struct ModelDownloaderTests {
    @Test("Unknown and zero content lengths keep progress finite", arguments: [Int64(-1), 0])
    func unknownLength(expected: Int64) {
        let progress = ModelDownloadProgress(totalBytesWritten: 12_000_000, totalBytesExpectedToWrite: expected)
        #expect(progress.fraction == 0)
        #expect(progress.status == "Downloading: 12 MB (total size unknown)")
    }

    @Test("Known content lengths produce bounded progress")
    func knownLength() {
        #expect(ModelDownloadProgress(totalBytesWritten: 50, totalBytesExpectedToWrite: 100).fraction == 0.5)
        #expect(ModelDownloadProgress(totalBytesWritten: 150, totalBytesExpectedToWrite: 100).fraction == 1)
        #expect(ModelDownloadProgress(totalBytesWritten: -1, totalBytesExpectedToWrite: 100).fraction == 0)
    }

    @Test("Storage failures preserve the filesystem error and allow a retry")
    func storageFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = ModelDownloader(modelDirectory: root.appendingPathComponent("Flare"))
        for _ in 0..<2 {
            do {
                _ = try await downloader.downloadModel { _, _ in }
                Issue.record("Expected a filesystem error before the network request")
            } catch {
                #expect((error as NSError).domain == NSCocoaErrorDomain)
            }
        }
    }
}

// A real loopback server is needed here: mocked response/progress arithmetic
// cannot catch URLSession suppressing delegate callbacks for async downloads.
import Network

@Suite("Model download transport")
struct ModelDownloadTransportTests {
    @Test("Reports intermediate progress and preserves the completed file", arguments: [true, false])
    @MainActor
    func streamsProgress(knownLength: Bool) async throws {
        let server = try ModelDownloadHTTPFixture(knownLength: knownLength)
        let url = try await server.start()
        defer { server.listener.cancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = ModelDownloader(modelDirectory: directory.appendingPathComponent("fresh/Flare"), modelURL: url)
        let recorder = DownloadProgressRecorder()
        let file = try await downloader.downloadModel { fraction, status in
            MainActor.assumeIsolated { recorder.updates.append((fraction, status)) }
        }
        #expect(recorder.updates.contains { $0.1.hasPrefix("Downloading:") })
        #expect(recorder.updates.allSatisfy { $0.0.isFinite && (0...1).contains($0.0) })
        if knownLength {
            #expect(recorder.updates.contains { $0.0 > 0 && $0.0 < 1 })
        }
        #expect(try Data(contentsOf: file) == Data(repeating: 42, count: 4 * 65_536))
    }
}

@MainActor
private final class DownloadProgressRecorder {
    var updates: [(Double, String)] = []
}

private final class ModelDownloadHTTPFixture: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "ModelDownloadHTTPFixture")
    private let knownLength: Bool

    init(knownLength: Bool) throws {
        self.knownLength = knownLength
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] _, _, _, _ in
                let length = knownLength ? "Content-Length: 262144\r\n" : ""
                let header = Data("HTTP/1.1 200 OK\r\n\(length)Connection: close\r\n\r\n".utf8)
                connection.send(content: header, completion: .contentProcessed { [self] _ in
                    sendChunk(connection, remaining: 4)
                })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/model")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func sendChunk(_ connection: NWConnection, remaining: Int) {
        guard remaining > 0 else { connection.cancel(); return }
        connection.send(content: Data(repeating: 42, count: 65_536), completion: .contentProcessed { [self] error in
            guard error == nil else { connection.cancel(); return }
            queue.asyncAfter(deadline: .now() + 0.1) { [self] in
                sendChunk(connection, remaining: remaining - 1)
            }
        })
    }
}
