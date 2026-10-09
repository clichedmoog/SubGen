import Foundation

/// Downloads data files without executing a system utility. Call off the main thread.
enum ModelDownloader {
    enum Failure: LocalizedError {
        case cancelled, timedOut, http(Int), transfer(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "다운로드를 중단했습니다."
            case .timedOut: return "다운로드 제한 시간을 초과했습니다."
            case .http(let code): return "다운로드 서버 오류 (HTTP \(code))"
            case .transfer(let message): return "다운로드 실패: \(message)"
            }
        }
    }

    private final class Transfer: @unchecked Sendable {
        let lock = NSLock()
        var error: Error?
    }

    static func download(_ source: URL, to destination: URL, timeout: TimeInterval,
                         cancellation: CancellationToken, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard !cancellation.isCancelled else { throw Failure.cancelled }
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = min(timeout, 60)
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        let transfer = Transfer()
        let task = session.downloadTask(with: source) { local, response, error in
            transfer.lock.lock()
            defer { transfer.lock.unlock(); done.signal() }
            do {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    throw Failure.http((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                guard let local else { throw Failure.transfer("빈 다운로드 결과") }
                // Never overwrite an existing model or staged file on transfer failure.
                try FileManager.default.moveItem(at: local, to: destination)
            } catch { transfer.error = error }
        }
        let deadline = Date().addingTimeInterval(timeout)
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
