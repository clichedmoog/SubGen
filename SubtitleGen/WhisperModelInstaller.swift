import Foundation

/// Shared by pre-download and lazy transcription. Call on a background queue.
enum WhisperModelInstaller {
    typealias Progress = (Int64, Int64?) -> Void
    typealias Download = (URL, URL, CancellationToken, @escaping Progress) throws -> Void

    static func isAvailable(at url: URL) -> Bool {
        guard (try? SafeFileReplacement.Snapshot(url).size) ?? 0 >= 10_000_000,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // GGML magic used by the pinned whisper.cpp model converter/loader.
        return (try? handle.read(upToCount: 4)) == Data([0x6c, 0x6d, 0x67, 0x67])
    }

    static func ensureAvailable(at destination: URL, cancellation: CancellationToken,
                                onProgress: @escaping Progress = { _, _ in },
                                download: Download = { source, staged, token, progress in
                                    try ModelDownloader.download(source, to: staged, timeout: 7200,
                                                                 cancellation: token, onProgress: progress)
                                }) throws {
        guard !cancellation.isCancelled else { throw ModelDownloader.Failure.cancelled }
        if isAvailable(at: destination) { return }
        guard let model = WhisperModel(rawValue: destination.lastPathComponent), let source = URL(string: model.downloadURL) else {
            throw ModelDownloader.Failure.transfer("선택한 음성인식 모델의 다운로드 정보를 찾을 수 없습니다.")
        }
        let fm = FileManager.default
        let expected = try? SafeFileReplacement.Snapshot(destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(model.rawValue)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        onProgress(0, nil)
        try download(source, staged, cancellation, onProgress)
        guard !cancellation.isCancelled else { throw ModelDownloader.Failure.cancelled }
        guard isAvailable(at: staged) else { throw ModelDownloader.Failure.transfer("다운로드한 음성인식 모델이 불완전하거나 형식이 올바르지 않습니다.") }
        if let expected {
            try SafeFileReplacement.replace(destination, with: staged, expected: expected)
        } else {
            // moveItem does not overwrite a model installed concurrently.
            try fm.moveItem(at: staged, to: destination)
        }
    }

    static func downloadDetail(received: Int64, total: Int64?) -> String {
        let receivedText = ByteCountFormatter.string(fromByteCount: max(0, received), countStyle: .file)
        guard let total, total > 0 else { return received > 0 ? receivedText : "연결 중…" }
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(receivedText) / \(totalText) · \(Int(min(1, max(0, Double(received) / Double(total))) * 100))%"
    }
}
