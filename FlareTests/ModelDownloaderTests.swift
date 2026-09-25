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
