import Foundation

/// Downloads data files without executing a system utility. Call off the main thread.
enum ModelDownloader {
    enum Failure: LocalizedError {
        case cancelled, timedOut, http(Int), transfer(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return String(localized: "다운로드를 중단했습니다.")
            case .timedOut: return String(localized: "다운로드 제한 시간을 초과했습니다.")
            case .http(let code): return String(localized: "다운로드 서버 오류 (HTTP \(code))")
            case .transfer(let message): return String(localized: "다운로드 실패: \(message)")
            }
        }
    }

    private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var error: Error?
        let progress: (Int64, Int64?) -> Void
        let destination: URL
        let cancellation: CancellationToken
        private var lastProgressAt = Date.distantPast
        init(destination: URL, cancellation: CancellationToken, progress: @escaping (Int64, Int64?) -> Void) {
            self.destination = destination; self.cancellation = cancellation; self.progress = progress
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = Date()
            lock.lock()
            let report = now.timeIntervalSince(lastProgressAt) >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite
            if report { lastProgressAt = now }
            lock.unlock()
            guard report else { return }
            progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    throw Failure.http((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                guard !cancellation.isCancelled else { throw Failure.cancelled }
                let size = try SafeFileReplacement.Snapshot(location).size
                // moveItem never overwrites a cached model or another staged file.
                try FileManager.default.moveItem(at: location, to: destination)
                progress(size, response.expectedContentLength > 0 ? response.expectedContentLength : nil)
            } catch {
                lock.lock(); self.error = error; lock.unlock()
            }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            if self.error == nil { self.error = error }
            lock.unlock(); done.signal()
        }
    }

    static func download(_ source: URL, to destination: URL, timeout: TimeInterval,
                         cancellation: CancellationToken, configuration: URLSessionConfiguration = .ephemeral,
                         onProgress: @escaping (Int64, Int64?) -> Void = { _, _ in }) throws {
        guard !cancellation.isCancelled else { throw Failure.cancelled }
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = min(timeout, 60)
        config.timeoutIntervalForResource = timeout
        let transfer = Transfer(destination: destination, cancellation: cancellation, progress: onProgress)
        let session = URLSession(configuration: config, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let done = transfer.done
        // Completion-handler downloads suppress download delegate progress callbacks.
        let task = session.downloadTask(with: source)
        let deadline = Date().addingTimeInterval(timeout)
        onProgress(0, nil)
        task.resume()
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellation.isCancelled || Date() >= deadline {
                task.cancel()
                // The callback may be moving a temporary file; wait before the caller cleans up.
                done.wait()
                throw cancellation.isCancelled ? Failure.cancelled : Failure.timedOut
            }
        }
        if cancellation.isCancelled { throw Failure.cancelled }
        transfer.lock.lock(); defer { transfer.lock.unlock() }
        if let error = transfer.error { throw error }
    }
}
