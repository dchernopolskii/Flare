//
//  ModelDownloader.swift
//  Flare
//
//  Created by Dan on 12/9/25.
//

import Foundation

actor ModelDownloader {
    static let shared = ModelDownloader()

    private let modelURL: URL
    private let modelDirectory: URL
    private let modelFileName = "llama32-3b-instruct-q4_k_m.gguf"

    private var isDownloading = false
    private var downloadTask: URLSessionDownloadTask?

    init(
        modelDirectory: URL? = nil,
        modelURL: URL = URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!
    ) {
        self.modelDirectory = modelDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flare", isDirectory: true)
        self.modelURL = modelURL
    }

    func getModelPath() -> URL {
        let modelPath = modelDirectory.appendingPathComponent(modelFileName)

        if !FileManager.default.fileExists(atPath: modelPath.path),
           let oldPath = legacyModelPaths().first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            do {
                try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: oldPath, to: modelPath)
            } catch {
                print("[ModelDownloader] Could not migrate legacy model: \(error)")
            }
        }

        return modelPath
    }

    private func legacyModelPaths() -> [URL] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let containerURL = appSupport.deletingLastPathComponent().deletingLastPathComponent()
        return [
            containerURL
                .appendingPathComponent("Data/Library/Application Support/Flare")
                .appendingPathComponent(modelFileName)
        ]
    }

    func isModelDownloaded() -> Bool {
        let path = getModelPath()
        let exists = FileManager.default.fileExists(atPath: path.path)
        if exists {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
               let fileSize = attrs[.size] as? Int64 {
                let sizeInGB = Double(fileSize) / 1_000_000_000
                print("[ModelDownloader] Model exists, size: \(String(format: "%.2f", sizeInGB)) GB")
                return fileSize > 1_000_000_000 // At least 1GB
            }
        }
        return false
    }

    func downloadModel(progressHandler: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let modelPath = getModelPath()

        if isModelDownloaded() {
            print("[ModelDownloader] Model already exists at: \(modelPath.path)")
            await MainActor.run {
                progressHandler(1.0, "Model ready")
            }
            return modelPath
        }

        guard !isDownloading else {
            throw ModelDownloadError.alreadyDownloading
        }

        isDownloading = true
        defer {
            isDownloading = false
            downloadTask = nil
        }

        print("[ModelDownloader] Starting download from: \(modelURL)")
        await MainActor.run {
            progressHandler(0.0, "Starting download...")
        }

        let delegate = DownloadDelegate { progress, status in
            Task { @MainActor in
                progressHandler(progress, status)
            }
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300 // 5 minutes
        configuration.timeoutIntervalForResource = 7200 // 2 hours
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        defer { session.invalidateAndCancel() }

        do {
            // A fresh sandbox may not have either directory yet. Do not hide
            // filesystem failures or wait until a multi-GB transfer finishes.
            try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: FileManager.default.temporaryDirectory, withIntermediateDirectories: true)
            // The async URLSession download API does not deliver download
            // progress callbacks on all supported macOS versions. Use an
            // explicit delegate-driven task and bridge its result to async.
            let (downloadedURL, response) = try await withCheckedThrowingContinuation { continuation in
                delegate.completion = { continuation.resume(with: $0) }
                let task = session.downloadTask(with: modelURL)
                downloadTask = task
                task.resume()
            }
            defer { try? FileManager.default.removeItem(at: downloadedURL) }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ModelDownloadError.invalidResponse
            }
            guard httpResponse.statusCode == 200 else {
                throw ModelDownloadError.httpStatus(httpResponse.statusCode)
            }

            if FileManager.default.fileExists(atPath: modelPath.path) {
                try FileManager.default.removeItem(at: modelPath)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: modelPath)

            print("[ModelDownloader] Download complete: \(modelPath.path)")
            await MainActor.run {
                progressHandler(1.0, "Download complete!")
            }

            return modelPath

        } catch {
            print("[ModelDownloader] Download failed: \(error)")
            await MainActor.run {
                progressHandler(0.0, "Download failed")
            }
            throw error
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        // Keep the in-flight guard until the task finishes cancelling.
        print("[ModelDownloader] Download cancelled")
    }

    func deleteModel() throws {
        let path = getModelPath()
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
            print("[ModelDownloader] Deleted model at: \(path.path)")
        }
    }

    func getModelSize() -> Double? {
        let path = getModelPath()
        guard FileManager.default.fileExists(atPath: path.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let fileSize = attrs[.size] as? Int64 else {
            return nil
        }
        return Double(fileSize) / 1_000_000_000
    }
}

struct ModelDownloadProgress {
    let fraction: Double
    let status: String

    init(totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let downloadedMB = Double(max(0, totalBytesWritten)) / 1_000_000
        if totalBytesExpectedToWrite > 0 {
            fraction = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
            status = String(format: "Downloading: %.0f / %.0f MB", downloadedMB, Double(totalBytesExpectedToWrite) / 1_000_000)
        } else {
            // URLSession uses -1 when the server does not supply a length.
            fraction = 0
            status = String(format: "Downloading: %.0f MB (total size unknown)", downloadedMB)
        }
    }
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Double, String) -> Void
    // Installed before resume(); consumed only on the serial delegate queue.
    var completion: ((Result<(URL, URLResponse), Error>) -> Void)?

    init(progressHandler: @escaping (Double, String) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let update = ModelDownloadProgress(totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        progressHandler(update.fraction, update.status)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response else {
                throw ModelDownloadError.invalidResponse
            }
            // URLSession removes location when this callback returns. Preserve
            // it before resuming the actor that installs the downloaded model.
            let stagingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("flare-model-\(UUID().uuidString).download")
            try FileManager.default.moveItem(at: location, to: stagingURL)
            progressHandler(1.0, "Processing...")
            finish(.success((stagingURL, response)))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        let handler = completion
        completion = nil
        handler?(result)
    }
}

enum ModelDownloadError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case alreadyDownloading

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The model server returned an invalid response. Please try again."
        case .httpStatus(let status):
            return "The model server returned HTTP \(status). Please try again."
        case .alreadyDownloading:
            return "Model is already being downloaded"
        }
    }
}
