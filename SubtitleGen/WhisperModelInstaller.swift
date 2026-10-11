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

    static let vadSource = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!

    static func vadURL(nextTo model: URL) -> URL {
        model.deletingLastPathComponent().appendingPathComponent(vadSource.lastPathComponent)
    }

    static func isVadAvailable(at url: URL) -> Bool {
        guard (try? SafeFileReplacement.Snapshot(url).size) ?? 0 >= 100_000,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // GGML magic, then the length-prefixed model type written by whisper.cpp's Silero converter.
        guard let header = try? handle.read(upToCount: 14), header.count == 14 else { return false }
        return header.prefix(4) == Data([0x6c, 0x6d, 0x67, 0x67]) && header.suffix(6) == Data("silero".utf8)
    }

    /// Without VAD, whisper.cpp starts cues where the preceding silence or music begins.
    static func isReady(model: URL) -> Bool {
        isAvailable(at: model) && isVadAvailable(at: vadURL(nextTo: model))
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
        try install(source, to: destination, isValid: isAvailable, invalid: "다운로드한 음성인식 모델이 불완전하거나 형식이 올바르지 않습니다.",
                    cancellation: cancellation, onProgress: onProgress, download: download)
    }

    static func ensureVadAvailable(nextTo model: URL, cancellation: CancellationToken,
                                   download: Download = { source, staged, token, progress in
                                       try ModelDownloader.download(source, to: staged, timeout: 330,
                                                                    cancellation: token, onProgress: progress)
                                   }) throws {
        guard !cancellation.isCancelled else { throw ModelDownloader.Failure.cancelled }
        let destination = vadURL(nextTo: model)
        if isVadAvailable(at: destination) { return }
        try install(vadSource, to: destination, isValid: isVadAvailable, invalid: "다운로드한 음성 구간 감지 모델이 불완전하거나 형식이 올바르지 않습니다.",
                    cancellation: cancellation, onProgress: { _, _ in }, download: download)
    }

    private static func install(_ source: URL, to destination: URL, isValid: (URL) -> Bool, invalid: String,
                                cancellation: CancellationToken, onProgress: @escaping Progress, download: Download) throws {
        let fm = FileManager.default
        let expected = try? SafeFileReplacement.Snapshot(destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        onProgress(0, nil)
        try download(source, staged, cancellation, onProgress)
        guard !cancellation.isCancelled else { throw ModelDownloader.Failure.cancelled }
        guard isValid(staged) else { throw ModelDownloader.Failure.transfer(invalid) }
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
