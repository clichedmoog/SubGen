import XCTest
import Combine
@testable import SubtitleGen

final class ProcessingProgressTests: XCTestCase {
    func testOptionChangesClearStaleStateButRetainKnownSourceLanguage() {
        var file = FileItem(url: URL(fileURLWithPath: "/movie.mp4"))
        file.status = .completed(lang: "en"); file.sourceLanguage = "en"
        file.progress = 1; file.phaseProgress = 1; file.elapsedTime = 30
        file.translatedLangs = ["ko"]; file.progressDetail = "old translation"
        var active = FileItem(url: URL(fileURLWithPath: "/active.mp4")); active.status = .translating(lang: "en"); active.progress = 0.6
        var files = [file, active]
        // The same reset is used for translation toggles, output mode, source-language changes and manual retries.
        FileItem.requeueAfterOptionsChange(&files)
        XCTAssertEqual(files[0].status, .pending); XCTAssertEqual(files[0].progress, 0)
        XCTAssertNil(files[0].phaseProgress); XCTAssertNil(files[0].elapsedTime)
        XCTAssertTrue(files[0].translatedLangs.isEmpty); XCTAssertEqual(files[0].progressDetail, "")
        XCTAssertEqual(files[0].sourceLanguage, "en"); XCTAssertEqual(files[1], active)
    }
    func testTranscriptionStartIsDetectedInAnyInterfaceLanguage() {
        let file = FileItem(url: URL(fileURLWithPath: "/movie.mp4"))
        var progress = ProcessingProgress()
        progress.sync([file], embed: false, targets: [], sourceLanguage: "en")
        progress.start(file.id)
        progress.update(file.id) { $0.source(0, detail: "Extracting audio… (1/1)") }
        XCTAssertNil(progress.files[file.id]!.transcriptionStartedAt)
        progress.update(file.id) { $0.source(0.1, detail: "Transcribing 00:00:01,500 / 00:00:03,000 · chunk 1/1 · en") }
        XCTAssertNotNil(progress.files[file.id]!.transcriptionStartedAt)
    }
    func testPendingSubsetAndParallelTranslationDoNotUseQueueIndexOrReach100Early() {
        var old = FileItem(url: URL(fileURLWithPath: "/old.mp4")); old.status = .completed(lang: "en")
        let first = FileItem(url: URL(fileURLWithPath: "/first.mp4")), second = FileItem(url: URL(fileURLWithPath: "/second.mp4"))
        var progress = ProcessingProgress()
        progress.sync([old, first, second], embed: true, targets: [.en, .ko, .ja], sourceLanguage: "en")
        XCTAssertEqual(progress.files.count, 2); XCTAssertEqual(progress.overall, 0)
        progress.start(first.id)
        progress.update(first.id) { $0.source(1, detail: "done"); $0.sourceReady(language: "en"); $0.sourceOutputDone = true }
        let beforeNext = progress.overall
        progress.start(second.id)
        progress.update(second.id) { $0.source(1, detail: "done"); $0.sourceOutputDone = true }
        XCTAssertGreaterThan(progress.overall, beforeNext)
        progress.update(first.id) { $0.translation(language: "ko", completed: 200, total: 405) }
        XCTAssertTrue(progress.files[first.id]!.detail.contains("한국어 200/405개"))
        XCTAssertTrue(progress.files[first.id]!.detail.contains("일본어 0/405개"))
        XCTAssertEqual(progress.files[first.id]!.phaseFraction!, Double(200) / 405 / 2, accuracy: 0.0001)
        for id in [first.id, second.id] {
            progress.update(id) {
                for lang in ["ko", "ja"] { $0.translation(language: lang, completed: 405, total: 405); $0.languageSaved(lang) }
            }
        }
        XCTAssertLessThan(progress.overall, 1, "Saving/embedding/final verification must finish before 100%")
        progress.finish(first.id, status: .completed(lang: "en")); XCTAssertLessThan(progress.overall, 1)
        progress.finish(second.id, status: .completed(lang: "en")); XCTAssertEqual(progress.overall, 1)
        progress.update(first.id) { $0.source(0, detail: "late stale callback") }
        XCTAssertEqual(progress.files[first.id]!.fraction, 1)
    }
    func testProgressIgnoresBackwardTimestampsAndQueueReordering() {
        let a = FileItem(url: URL(fileURLWithPath: "/a.mp4")), b = FileItem(url: URL(fileURLWithPath: "/b.mp4"))
        var progress = ProcessingProgress(); progress.sync([a, b], embed: false, targets: [], sourceLanguage: "en")
        progress.start(a.id); progress.update(a.id) { $0.source(0.4, detail: "00:40 / 01:40") }
        let before = progress.overall
        progress.update(a.id) { $0.source(0.1, detail: "old timestamp") }
        progress.sync([b, a], embed: false, targets: [], sourceLanguage: "en")
        XCTAssertEqual(progress.overall, before); XCTAssertEqual(progress.files[a.id]!.detail, "00:40 / 01:40")
        progress.finish(a.id, status: .failed(error: "failed")); progress.finish(b.id, status: .skipped)
        XCTAssertEqual(progress.overall, 1); XCTAssertLessThan(progress.files[a.id]!.fraction, 1)
    }
    func testTranslationCountsOnlyValidatedChunksAndDoesNotCountRetries() throws {
        let original = SrtDocument(cues: (1...405).map { .init(number: $0, start: Double($0 * 2), end: Double($0 * 2 + 1), text: "Hello") })
        var requests = 0, received: [Int] = []
        let translator = TranslationEngine(authMethod: .codex, request: { content, _ in
            requests += 1
            if requests == 1 { return ProcessResult(stdout: "invalid partial", exitCode: 0) }
            return ProcessResult(stdout: content, exitCode: 0)
        })
        let result = translator.translateSrt(srtContent: original.render(), sourceLang: "en", targetLangs: [.ko], onProgress: { _ in },
            onCueProgress: { _, completed, total in XCTAssertEqual(total, 405); received.append(completed) })
        XCTAssertEqual(received, [0, 200, 400, 405]); XCTAssertEqual(requests, 4)
        XCTAssertNotNil(result.translations[.ko])
    }
    func testSourceSelectionUsesRequestedOrRememberedLanguageAndAvoidsRelabelingUnknown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["movie.srt", "movie.en.srt", "movie.ko.srt"] { try Data().write(to: directory.appendingPathComponent(name)) }
        var file = FileItem(url: directory.appendingPathComponent("movie.mp4")); file.sourceLanguage = "ko"
        XCTAssertEqual(TranscriptionEngine.sourceSidecars(for: file, language: "en").first?.language, "en")
        XCTAssertEqual(TranscriptionEngine.sourceSidecars(for: file, language: "").first?.language, "ko")
        XCTAssertTrue(TranscriptionEngine.sourceSidecars(for: file, language: "ja").isEmpty)
        file.sourceLanguage = "und"
        XCTAssertEqual(TranscriptionEngine.sourceSidecars(for: file, language: "ja").first?.language, "und")
    }
    func testAutomaticModeRetainsRememberedLanguageForAnUntypedSrt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var file = FileItem(url: directory.appendingPathComponent("movie.mp4")); file.sourceLanguage = "en"
        try "1\n00:00:00,000 --> 00:00:01,000\nHello\n".write(to: directory.appendingPathComponent("movie.srt"), atomically: true, encoding: .utf8)
        let options = TranscriptionEngine.Options(model: "/unused", embedSubtitle: false, keepSrtFile: true,
            subtitleDelay: 0, sensitivity: .normal, language: "", translationTargets: [], authMethod: .codex, translationModel: "")
        let source = try TranscriptionEngine().prepareSource(file: file, whisper: "/unused", ffmpeg: "/unused", ffprobe: "/unused", options: options, token: CancellationToken())
        XCTAssertEqual(source.language, "en"); XCTAssertFalse(source.created)
    }
    func testOriginalLanguageMetadataSurvivesReloadWithoutSavingStaleProgress() throws {
        let suite = "processing-language-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        var file = FileItem(url: URL(fileURLWithPath: "/original-ja.mp4"))
        file.sourceLanguage = "ja"; file.progress = 0.7; file.status = .translating(lang: "en")
        FileItem.saveSourceLanguages([file], defaults: defaults)
        XCTAssertEqual(FileItem.savedSourceLanguage(for: file.url, defaults: defaults), "ja")
        XCTAssertNil(FileItem.savedSourceLanguage(for: URL(fileURLWithPath: "/another.mp4"), defaults: defaults))
        let values = try XCTUnwrap(defaults.dictionary(forKey: "savedFileSourceLanguages"))
        XCTAssertEqual(values.count, 1); XCTAssertEqual(values[file.url.path] as? String, "ja")
        FileItem.saveSourceLanguages([], defaults: defaults)
        XCTAssertNil(FileItem.savedSourceLanguage(for: file.url, defaults: defaults))
    }
}

final class ProcessingPipelineIntegrationTests: XCTestCase {
    private var directory: URL!
    private var ffmpeg: String!
    private var ffprobe: String!
    private var whisper: String!
    private var video: URL!
    private let srt = "1\n00:00:00,000 --> 00:00:01,500\nHello from this subtitle.\n"

    override func setUpWithError() throws {
        guard let ffmpeg = ToolResolver.find("ffmpeg"), let ffprobe = ToolResolver.find("ffprobe") else { throw XCTSkip("Native media tools required") }
        self.ffmpeg = ffmpeg; self.ffprobe = ffprobe
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("progress-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        video = directory.appendingPathComponent("movie.mp4")
        let result = ProcessRunner.run(ffmpeg, arguments: ["-v", "error", "-f", "lavfi", "-i", "color=c=black:size=160x90:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:v", "mpeg4", "-c:a", "aac", "-shortest", video.path], timeout: 20)
        XCTAssertTrue(result.succeeded, result.diagnostic)
        whisper = directory.appendingPathComponent("whisper-fixture").path
        let script = """
        #!/bin/sh
        destination=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '-of' ]; then destination="$2"; shift; fi
          shift
        done
        echo '[00:00:00.000 --> 00:00:01.500] Hello from this subtitle.'
        cat > "$destination.srt" <<'SRT'
        \(srt)
        SRT
        """
        try script.write(toFile: whisper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: whisper)
    }
    override func tearDownWithError() throws { if let directory { try FileManager.default.removeItem(at: directory) } }
    private func options(language: String = "en", embed: Bool = false, targets: Set<TranslationLanguage> = []) -> TranscriptionEngine.Options {
        .init(model: directory.appendingPathComponent("model.bin").path, embedSubtitle: embed, keepSrtFile: !embed,
            subtitleDelay: 0, sensitivity: .normal, language: language, translationTargets: targets, authMethod: .codex, translationModel: "")
    }
    @MainActor
    private func run(_ files: [FileItem], options: TranscriptionEngine.Options,
                     prepareModel: ((URL, CancellationToken, @escaping WhisperModelInstaller.Progress) throws -> Void)? = nil,
                     configure: (TranscriptionEngine) -> Void = { _ in }) async throws -> ([FileItem], Double, [Double], [String]) {
        var queue = files, observations: [Double] = [], details: [String] = []
        let resolver: (String) -> String? = { [self] name in name == "whisper-cli" ? whisper : (name == "ffmpeg" ? ffmpeg : ffprobe) }
        let engine = prepareModel.map { TranscriptionEngine(binaryResolver: resolver, prepareModel: $0) } ?? TranscriptionEngine(binaryResolver: resolver)
        configure(engine)
        let done = expectation(description: "pipeline completed")
        engine.process(getFiles: { queue }, options: options, onFileUpdate: { id, status, elapsed in
            guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
            queue[index].status = status; if let elapsed { queue[index].elapsedTime = elapsed }
        }, onFileProgress: { id, fraction in
            if let index = queue.firstIndex(where: { $0.id == id }) { queue[index].progress = fraction }
        }, onTranslationComplete: { id, language in
            if let index = queue.firstIndex(where: { $0.id == id }) { queue[index].translatedLangs.append(language) }
        }, onFileDetail: { _, detail, phase in details.append(detail); if let phase { observations.append(phase) } },
           onSourcePrepared: { id, language in if let index = queue.firstIndex(where: { $0.id == id }) { queue[index].sourceLanguage = language } })
        let watch = engine.$isProcessing.filter { !$0 }.prefix(1).sink { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 15); watch.cancel()
        return (queue, engine.overallProgress, observations, details)
    }
    @MainActor
    func testTranscribeThenEnableTranslationAndEmbeddingReusesSourceWithFreshCompletion() async throws {
        let source = directory.appendingPathComponent("movie.en.srt")
        try srt.write(to: source, atomically: true, encoding: .utf8)
        let initial = try await run([FileItem(url: video)], options: options())
        XCTAssertEqual(initial.0[0].status, .completed(lang: "en")); XCTAssertEqual(initial.0[0].progress, 1)
        XCTAssertEqual(initial.1, 1)
        var files = initial.0; FileItem.requeueAfterOptionsChange(&files)
        try srt.replacingOccurrences(of: "Hello from this subtitle.", with: "안녕하세요.").write(to: directory.appendingPathComponent("movie.ko.srt"), atomically: true, encoding: .utf8)
        let translated = try await run(files, options: options(targets: [.ko]))
        XCTAssertEqual(translated.0[0].translatedLangs, ["ko"]); XCTAssertEqual(translated.0[0].progress, 1)
        XCTAssertTrue(translated.3.contains(where: { $0.contains("한국어 1/1개") }))
        files = translated.0; FileItem.requeueAfterOptionsChange(&files)
        let embedded = try await run(files, options: options(embed: true, targets: [.ko]))
        XCTAssertEqual(embedded.0[0].status, .completed(lang: "en")); XCTAssertEqual(embedded.1, 1)
        XCTAssertTrue(embedded.3.contains("원본 자막 내장·검증 중..."))
        XCTAssertEqual(try String(contentsOf: source), srt)
    }
    @MainActor
    func testSourceLanguageChangeTranscribesRequestedLanguageAndReportsActualTime() async throws {
        try srt.write(to: directory.appendingPathComponent("movie.en.srt"), atomically: true, encoding: .utf8)
        let initial = try await run([FileItem(url: video)], options: options())
        var files = initial.0; FileItem.requeueAfterOptionsChange(&files)
        // Sparse test models meet the size checks; the fixture recognizer supplies timestamped output.
        try prepareFixtureModel()
        let changed = try await run(files, options: options(language: "ko"))
        XCTAssertEqual(changed.0[0].status, .completed(lang: "ko")); XCTAssertEqual(changed.0[0].sourceLanguage, "ko")
        XCTAssertTrue(changed.2.contains { $0 > 0.45 && $0 < 0.55 })
        XCTAssertTrue(changed.3.contains { $0.contains("00:00:01,500 / 00:00:03,000") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("movie.ko.srt").path))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("movie.en.srt")), srt)
    }

    private func prepareFixtureModel(vad: Bool = true) throws {
        FileManager.default.createFile(atPath: options().model, contents: nil)
        let model = try FileHandle(forWritingTo: URL(fileURLWithPath: options().model)); defer { try? model.close() }
        try model.write(contentsOf: Data([0x6c, 0x6d, 0x67, 0x67])); try model.truncate(atOffset: 10_000_000)
        guard vad else { return }
        var data = Data([0x6c, 0x6d, 0x67, 0x67, 0x0a, 0, 0, 0]); data += Data("silero-16k".utf8); data += Data(count: 200_000)
        try data.write(to: WhisperModelInstaller.vadURL(nextTo: URL(fileURLWithPath: options().model)))
    }
    private func fixtureRecognizer(srt: String, log: String = "") throws {
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "$(dirname "$0")/whisper-arguments.txt"
        destination=''
        progress=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '-of' ]; then destination="$2"; shift; fi
          if [ "$1" = '--print-progress' ]; then progress='yes'; fi
          shift
        done
        [ "$progress" = 'yes' ] || exit 9
        printf 'whisper_print_progress_callback: progress = 50%%\\n' >&2
        cat >&2 <<'LOG'
        \(log)
        LOG
        sleep 0.2
        cat > "$destination.srt" <<'SRT'
        \(srt)
        SRT
        """
        try script.write(toFile: whisper, atomically: true, encoding: .utf8)
    }
    @MainActor
    func testBlankWhisperCueAndNativeProgressContinueThroughVideoEmbedding() async throws {
        try prepareFixtureModel()
        try fixtureRecognizer(srt: "1\n00:00:00,000 --> 00:00:00,000\n\n2\n00:00:00,200 --> 00:00:02,200\nHello from this subtitle.\n")
        let result = try await run([FileItem(url: video)], options: options(embed: true))
        XCTAssertEqual(result.0[0].status, .completed(lang: "en"))
        XCTAssertTrue(result.2.contains { $0 > 0.49 && $0 < 0.51 })
        XCTAssertTrue(result.3.contains { $0.contains("전사 추정") && $0.contains("00:00:01,500 / 00:00:03,000") })
        let probe = ProcessRunner.run(ffprobe, arguments: ["-v", "error", "-select_streams", "s", "-show_entries", "stream=codec_name", "-of", "csv=p=0", video.path], timeout: 10)
        XCTAssertTrue(probe.succeeded); XCTAssertTrue(probe.stdout.contains("mov_text"))
    }
    @MainActor
    func testTranscriptionUsesVadWithSpeechThreshold() async throws {
        try prepareFixtureModel()
        try fixtureRecognizer(srt: "1\n00:00:00,200 --> 00:00:02,200\nHello from this subtitle.\n")
        let result = try await run([FileItem(url: video)], options: options())
        XCTAssertEqual(result.0[0].status, .completed(lang: "en"))
        let arguments = try String(contentsOf: directory.appendingPathComponent("whisper-arguments.txt")).components(separatedBy: "\n")
        let vad = WhisperModelInstaller.vadURL(nextTo: URL(fileURLWithPath: options().model)).path
        XCTAssertTrue(arguments.contains("--vad"))
        XCTAssertEqual(arguments.firstIndex(of: "--vad-model").map { arguments[$0 + 1] }, vad)
        XCTAssertEqual(arguments.firstIndex(of: "--vad-threshold").map { arguments[$0 + 1] }, "0.5")
    }
    @MainActor
    func testWhisperCueStartsAtReportedSpeechInsteadOfPrecedingSilence() async throws {
        try prepareFixtureModel()
        try fixtureRecognizer(srt: "1\n00:00:00,000 --> 00:00:02,600\nHello from this subtitle.\n",
            log: "whisper_vad_segments_from_probs: VAD segment 0: start = 1.20, end = 2.40 (duration: 1.20)")
        let result = try await run([FileItem(url: video)], options: options())
        XCTAssertEqual(result.0[0].status, .completed(lang: "en"))
        let source = try String(contentsOf: directory.appendingPathComponent("movie.en.srt"))
        XCTAssertEqual(try SrtDocument(source).cues.count, 1)
        XCTAssertTrue(source.contains("00:00:01,200 --> 00:00:02,400"), source)
    }
    @MainActor
    func testMissingVadFailsInsteadOfTranscribingWithoutSpeechDetection() async throws {
        try prepareFixtureModel(vad: false)
        try fixtureRecognizer(srt: "1\n00:00:00,000 --> 00:00:02,200\nHello from this subtitle.\n")
        let result = try await run([FileItem(url: video)], options: options(), prepareModel: { _, _, _ in })
        guard case .failed(let message) = result.0[0].status else { return XCTFail("Missing VAD must not produce untrimmed subtitles") }
        XCTAssertTrue(message.contains("음성 구간 감지"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("whisper-arguments.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("movie.en.srt").path))
    }
    @MainActor
    func testAppleTranslationInTheDirectBuildAsksForLanguagePacks() async throws {
        try srt.write(to: directory.appendingPathComponent("movie.en.srt"), atomically: true, encoding: .utf8)
        var opts = options(targets: [.ko]); opts.translationProvider = .apple
        var requested: [String] = []
        let result = try await run([FileItem(url: video)], options: opts, configure: { engine in
            engine.appleLanguagePack = { source, target, _ in
                requested.append("\(source)>\(target.rawValue)")
                return .failed("한국어 언어 팩 다운로드가 허용되지 않았습니다.")
            }
        })
        XCTAssertEqual(requested, ["en>ko"])
        guard case .failed(let message) = result.0[0].status else { return XCTFail("A refused pack must fail that translation") }
        XCTAssertTrue(message.contains("언어 팩"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("movie.en.srt").path))
    }
    @MainActor
    func testMalformedWhisperOutputPreservesDiagnosticAndOriginalVideo() async throws {
        try prepareFixtureModel()
        let invalid = "1\n00:00:02,000 --> 00:00:01,000\nDiagnostic dialogue.\n"
        try fixtureRecognizer(srt: invalid)
        let original = try Data(contentsOf: video)
        let result = try await run([FileItem(url: video)], options: options(embed: true))
        guard case .failed(let message) = result.0[0].status else { return XCTFail("Malformed timings must fail") }
        XCTAssertTrue(message.contains("1번")); XCTAssertTrue(message.contains("보존"))
        XCTAssertEqual(try Data(contentsOf: video), original)
        let diagnostics = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(".diagnostic.srt") }
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(diagnostics.first)).contains("Diagnostic dialogue."))
        XCTAssertTrue(TranscriptionEngine.sidecars(for: video).isEmpty, "Diagnostics must never be mistaken for reusable source subtitles")
    }
}
