import XCTest
@testable import SubtitleGen

final class FFmpegIntegrationTests: XCTestCase {
    private var directory: URL!
    private var ffmpeg: String!
    private var ffprobe: String!
    private var video: URL!
    private var source: URL!
    private let token = CancellationToken()
    private let engine = TranscriptionEngine()

    private var options: TranscriptionEngine.Options {
        .init(model: WhisperModel.largev3turbo.modelPath, embedSubtitle: false, keepSrtFile: true,
              subtitleDelay: 0, sensitivity: .normal, language: "en", translationTargets: [],
              authMethod: .claudeCode, translationModel: "")
    }

    override func setUpWithError() throws {
        let override = ProcessInfo.processInfo.environment["SUBTITLEGEN_FFMPEG_DIR"]
        let candidates = override.map { URL(fileURLWithPath: $0) }
        guard let ffmpeg = ToolResolver.find("ffmpeg", candidates: candidates.map { [$0.appendingPathComponent("ffmpeg").path] }),
              let ffprobe = ToolResolver.find("ffprobe", candidates: candidates.map { [$0.appendingPathComponent("ffprobe").path] }) else {
            throw XCTSkip("Native FFmpeg/FFprobe required for media integration tests")
        }
        self.ffmpeg = ffmpeg; self.ffprobe = ffprobe
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("subtitlegen-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        video = directory.appendingPathComponent("sample.mp4")
        source = directory.appendingPathComponent("sample.en.srt")
        let result = ProcessRunner.run(ffmpeg, arguments: ["-v", "error", "-f", "lavfi", "-i", "color=c=black:size=160x90:duration=3", "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:v", "mpeg4", "-c:a", "aac", "-shortest", video.path], timeout: 20)
        XCTAssertTrue(result.succeeded, result.diagnostic)
        try "1\n00:00:00,200 --> 00:00:02,200\nHello from the embedded subtitle.\n".write(to: source, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testEmbeddedSubtitleCanBeRecoveredAsSrtWithoutTranscription() throws {
        XCTAssertTrue(try engine.embed(source, language: "en", into: video, ffmpeg: ffmpeg, ffprobe: ffprobe, token: token))
        try FileManager.default.removeItem(at: source)
        let lazyEngine = TranscriptionEngine(prepareModel: { _, _, _ in XCTFail("Embedded subtitles must not download a speech model") })
        let prepared = try lazyEngine.prepareSource(file: FileItem(url: video), whisper: "/not-used", ffmpeg: ffmpeg, ffprobe: ffprobe, options: options, token: token)
        XCTAssertEqual(prepared.language, "en")
        XCTAssertTrue(try String(contentsOf: prepared.url).contains("Hello from the embedded subtitle."))
        XCTAssertTrue(prepared.created)
    }

    func testExistingSrtSkipsModelAndCancelledModelPreparationPreservesMedia() throws {
        let lazyEngine = TranscriptionEngine(prepareModel: { _, token, progress in
            progress(10, 100); token.cancel(); throw ModelDownloader.Failure.cancelled
        })
        // No download or recognizer is needed while an exact matching SRT exists.
        let existing = try lazyEngine.prepareSource(file: FileItem(url: video), whisper: "/not-used", ffmpeg: ffmpeg, ffprobe: ffprobe, options: options, token: token)
        XCTAssertFalse(existing.created); XCTAssertFalse(token.isCancelled)
        try FileManager.default.removeItem(at: source)
        let before = try Data(contentsOf: video)
        var progressSeen = false
        XCTAssertThrowsError(try lazyEngine.prepareSource(file: FileItem(url: video), whisper: "/not-used", ffmpeg: ffmpeg, ffprobe: ffprobe, options: options, token: token,
            onModelDownload: { _, _ in progressSeen = true }))
        XCTAssertTrue(progressSeen); XCTAssertTrue(token.isCancelled)
        XCTAssertEqual(try Data(contentsOf: video), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testFailedEmbeddingPreservesOriginalAndSourceSrt() throws {
        let original = try Data(contentsOf: video)
        XCTAssertThrowsError(try engine.embed(source, language: "en", into: video, ffmpeg: "/usr/bin/false", ffprobe: ffprobe, token: token))
        XCTAssertEqual(try Data(contentsOf: video), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMissingSourceSrtIsReportedAsFailure() {
        let missing = TranscriptionEngine.SourceSubtitle(url: directory.appendingPathComponent("missing.en.srt"), language: "en", created: false)
        let status = engine.translateFile(file: FileItem(url: video), source: missing, sourceEmbedded: false,
            ffmpeg: ffmpeg, ffprobe: ffprobe, options: options, token: token, onStatusUpdate: { _ in }, onLangComplete: { _ in })
        guard case .failed = status else { return XCTFail("Missing source must fail, not complete") }
    }

    func testExistingUserSrtIsPreservedAfterSuccessfulTranslationReuse() throws {
        let korean = directory.appendingPathComponent("sample.ko.srt")
        let content = "1\n00:00:00,200 --> 00:00:02,200\n안녕하세요.\n"
        try content.write(to: korean, atomically: true, encoding: .utf8)
        var opts = options
        opts.embedSubtitle = true; opts.keepSrtFile = false; opts.translationTargets = [.ko]
        let original = try String(contentsOf: source)
        let status = engine.translateFile(file: FileItem(url: video), source: .init(url: source, language: "en", created: false), sourceEmbedded: false,
            ffmpeg: ffmpeg, ffprobe: ffprobe, options: opts, token: token, onStatusUpdate: { _ in }, onLangComplete: { _ in })
        XCTAssertEqual(status, .completed(lang: "en"))
        XCTAssertEqual(try String(contentsOf: korean), content)
        XCTAssertEqual(try String(contentsOf: source), original)
    }

    func testActualWavExtractionStartsAtRequestedPosition() throws {
        let wav = directory.appendingPathComponent("chunk.wav")
        let result = AudioPreparation.extract(source: video, chunk: .init(start: 1, duration: 1), destination: wav, ffmpeg: ffmpeg, cancellation: token)
        XCTAssertTrue(result.succeeded, result.diagnostic)
        let duration = ProcessRunner.run(ffprobe, arguments: ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", wav.path], timeout: 10)
        XCTAssertEqual(Double(duration.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, 1, accuracy: 0.05)
    }

    func testEmbeddingPreservesExistingSubtitleCodec() throws {
        let mkv = directory.appendingPathComponent("styled.mkv")
        let initial = ProcessRunner.run(ffmpeg, arguments: ["-v", "error", "-i", video.path, "-i", source.path, "-map", "0", "-map", "1:0", "-c", "copy", "-c:s", "ass", "-metadata:s:s:0", "language=eng", mkv.path], timeout: 20)
        XCTAssertTrue(initial.succeeded, initial.diagnostic)
        let korean = directory.appendingPathComponent("styled.ko.srt")
        try "1\n00:00:00,200 --> 00:00:02,200\n안녕하세요.\n".write(to: korean, atomically: true, encoding: .utf8)
        try engine.embed(korean, language: "ko", into: mkv, ffmpeg: ffmpeg, ffprobe: ffprobe, token: token)
        let codecs = ProcessRunner.run(ffprobe, arguments: ["-v", "error", "-select_streams", "s", "-show_entries", "stream=codec_name", "-of", "csv=p=0", mkv.path], timeout: 10)
        XCTAssertEqual(codecs.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n"), ["ass", "subrip"])
    }

    func testRealWhisperCanTranscribeExtractedSpeech() throws {
        guard ProcessInfo.processInfo.environment["SUBTITLEGEN_WHISPER_TEST"] == "1" else {
            throw XCTSkip("Set SUBTITLEGEN_WHISPER_TEST=1 to run local speech-model verification")
        }
        guard let whisper = ToolResolver.find("whisper-cli", candidates: ProcessInfo.processInfo.environment["SUBTITLEGEN_WHISPER_DIR"].map { ["\($0)/whisper-cli"] }), WhisperModel.largev3turbo.isCached else {
            throw XCTSkip("Local whisper-cli and Large v3 Turbo model required")
        }
        let audio = directory.appendingPathComponent("speech.aiff")
        let speech = ProcessRunner.run("/usr/bin/say", arguments: ["-v", "Samantha", "-o", audio.path,
            "This is a test of automatic language detection. The application creates subtitles and translates spoken words."], timeout: 30)
        XCTAssertTrue(speech.succeeded, speech.diagnostic)
        var opts = options
        opts.language = ""
        let prepared = try engine.prepareSource(file: FileItem(url: audio), whisper: whisper, ffmpeg: ffmpeg, ffprobe: ffprobe, options: opts, token: token)
        XCTAssertEqual(prepared.language, "en")
        let document = try SrtDocument(String(contentsOf: prepared.url))
        XCTAssertTrue(document.cues.contains { $0.text.lowercased().contains("language detection") })
    }

    func testRealWhisperRestoresTimeAcrossThirtyMinuteBoundary() throws {
        guard ProcessInfo.processInfo.environment["SUBTITLEGEN_WHISPER_TEST"] == "1",
              let whisper = ToolResolver.find("whisper-cli", candidates: ProcessInfo.processInfo.environment["SUBTITLEGEN_WHISPER_DIR"].map { ["\($0)/whisper-cli"] }), WhisperModel.largev3turbo.isCached else {
            throw XCTSkip("Opt-in local Whisper verification required")
        }
        let speech = directory.appendingPathComponent("boundary.aiff")
        let say = ProcessRunner.run("/usr/bin/say", arguments: ["-v", "Samantha", "-o", speech.path,
            "The first sentence describes the beginning of a subtitle. The second sentence crosses a chunk boundary and must keep the original time in the video. This final sentence is after thirty minutes."], timeout: 30)
        XCTAssertTrue(say.succeeded, say.diagnostic)
        let padded = directory.appendingPathComponent("padded.wav")
        let pad = ProcessRunner.run(ffmpeg, arguments: ["-v", "error", "-i", speech.path, "-af", "adelay=1795000:all=1", "-ar", "16000", "-ac", "1", padded.path], timeout: 30)
        XCTAssertTrue(pad.succeeded, pad.diagnostic)
        let prepared = try engine.prepareSource(file: FileItem(url: padded), whisper: whisper, ffmpeg: ffmpeg, ffprobe: ffprobe, options: options, token: token)
        let document = try SrtDocument(String(contentsOf: prepared.url))
        XCTAssertTrue(document.cues.allSatisfy { $0.start >= 1790 }, "Speech starts near 29:55, not at zero")
        XCTAssertTrue(document.cues.contains { $0.start >= 1800 }, "The second chunk must keep its original video time")
    }
}
