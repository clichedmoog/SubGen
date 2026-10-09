import XCTest
import Darwin
@testable import SubtitleGen

final class ProcessRunnerTests: XCTestCase {
    func testDrainsLargeStdoutAndStderrWithoutProgressCallback() {
        let result = ProcessRunner.run("/bin/sh", arguments: ["-c", "head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2"], timeout: 5)
        XCTAssertTrue(result.succeeded, result.diagnostic)
        XCTAssertEqual(result.stdout.utf8.count, 262144)
        XCTAssertEqual(result.stderr.utf8.count, 262144)
    }

    func testPromptLargerThanPipeCapacityCanBeSentAndRead() {
        let prompt = String(repeating: "번역할 대사\n", count: 20000)
        let result = ProcessRunner.run("/bin/cat", arguments: [], input: prompt, timeout: 5)
        XCTAssertTrue(result.succeeded, result.diagnostic)
        XCTAssertEqual(result.stdout, prompt)
    }

    func testTimeoutStopsProcessAndItsChild() {
        let start = Date()
        let result = ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 30 & echo $!; wait"], timeout: 0.15)
        XCTAssertEqual(result.failure, .timedOut)
        if let pid = Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            XCTAssertEqual(Darwin.kill(pid, 0), -1, "Child process must be gone")
        } else { XCTFail("Expected child PID") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testCancelStopsAllProcessesForFile() {
        let token = CancellationToken()
        let done = expectation(description: "both children stopped")
        done.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            DispatchQueue.global().async {
                let result = ProcessRunner.run("/bin/sleep", arguments: ["30"], timeout: 10, cancellation: token)
                XCTAssertEqual(result.failure, .cancelled)
                done.fulfill()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel() }
        wait(for: [done], timeout: 4)
    }

    func testPrecancelledProcessDoesNotRun() {
        let token = CancellationToken()
        token.cancel()
        XCTAssertEqual(ProcessRunner.run("/bin/echo", arguments: ["never"], cancellation: token).failure, .cancelled)
    }

    func testChildIgnoringTerminationIsStillStopped() {
        let result = ProcessRunner.run("/bin/sh", arguments: ["-c", "sh -c 'trap \"\" TERM; sleep 30' & echo $!; wait"], timeout: 0.2)
        XCTAssertEqual(result.failure, .timedOut)
        if let pid = Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            XCTAssertEqual(Darwin.kill(pid, 0), -1)
        } else { XCTFail("Expected child PID") }
    }

    func testMissingBinaryIsReported() {
        let result = ProcessRunner.run("/does/not/exist", arguments: [])
        guard case .launch = result.failure else { return XCTFail("Expected launch error") }
    }

    func testChildClosingStdinDoesNotCrashParent() {
        let result = ProcessRunner.run("/bin/sh", arguments: ["-c", "exit 1"], input: String(repeating: "x", count: 262144), timeout: 5)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 1)
    }
}

final class ToolResolverTests: XCTestCase {
    func testRejectsIntelOnArmAndArmOnIntel() {
        let arm = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1])
        let intel = Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1])
        XCTAssertTrue(ToolResolver.hasArchitecture(arm, cpuType: 0x0100000c))
        XCTAssertFalse(ToolResolver.hasArchitecture(intel, cpuType: 0x0100000c))
        XCTAssertTrue(ToolResolver.hasArchitecture(intel, cpuType: 0x01000007))
        XCTAssertFalse(ToolResolver.hasArchitecture(arm, cpuType: 0x01000007))
    }

    func testUniversalBinarySupportsBothCPUs() {
        var data = Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2, 1, 0, 0, 7])
        data.append(Data(repeating: 0, count: 16))
        data.append(Data([1, 0, 0, 0x0c]))
        data.append(Data(repeating: 0, count: 16))
        XCTAssertTrue(ToolResolver.hasArchitecture(data, cpuType: 0x0100000c))
        XCTAssertTrue(ToolResolver.hasArchitecture(data, cpuType: 0x01000007))
        XCTAssertFalse(ToolResolver.hasArchitecture(Data(), cpuType: 0x0100000c))
    }

    func testUnrunnableNativeCandidateFallsBack() {
        XCTAssertEqual(ToolResolver.find("ffmpeg", candidates: ["/does/not/exist", "/usr/bin/false", "/bin/echo"]), "/bin/echo")
    }

    func testDownloadsUseMatchingArchitecture() {
        for name in ["ffmpeg", "ffprobe"] {
            XCTAssertTrue(FFmpegDistribution.download(name, architecture: "arm64").url.path.contains("arm"))
            XCTAssertTrue(FFmpegDistribution.download(name, architecture: "x86_64").url.path.contains("intel"))
        }
    }
}

final class SubtitleValidationTests: XCTestCase {
    private let original = "1\n00:00:01,000 --> 00:00:03,000\nSorry, I cannot hear you.\n\n2\n00:00:04,000 --> 00:00:06,000\nPlease repeat.\n"

    func testNormalDialogueIsNotMistakenForRefusal() throws {
        XCTAssertEqual(try SrtDocument(original).cues.count, 2)
        XCTAssertTrue(TranslationEngine(authMethod: .claudeCode).isValidSrt(original))
    }

    func testMalformedLaterCueIsRejected() {
        XCTAssertThrowsError(try SrtDocument(original.replacingOccurrences(of: "00:00:04,000", with: "invalid")))
    }

    func testMissingCueAndChangedTimingAreRejected() throws {
        let source = try SrtDocument(original)
        XCTAssertFalse(try SrtDocument(source.cues.first.map { SrtDocument(cues: [$0]).render() }!).matchesTiming(of: source))
        XCTAssertFalse(try SrtDocument(original.replacingOccurrences(of: "00:00:04,000", with: "00:00:05,000")).matchesTiming(of: source))
    }

    func testCRLFAndBOMAreSupported() throws {
        let content = "\u{feff}" + original.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try SrtDocument(content).cues, try SrtDocument(original).cues)
    }

    func testChunkTimestampRestoresOriginalVideoTime() throws {
        let result = try SrtDocument(original).shifted(by: 1800)
        XCTAssertEqual(result.cues[0].start, 1801)
        XCTAssertTrue(result.render().contains("00:30:01,000"))
    }

    func testTranslationFailureIsReturnedAndSuccessRetainsTiming() {
        let translator = TranslationEngine(authMethod: .claudeCode, request: { srt, lang in
            lang == .ko ? ProcessResult(stdout: srt.replacingOccurrences(of: "Please repeat.", with: "다시 말해주세요."), exitCode: 0)
                : ProcessResult(stderr: "authentication failed", exitCode: 1)
        })
        let result = translator.translateSrt(srtContent: original, sourceLang: "en", targetLangs: [.ko, .ja], onProgress: { _ in })
        XCTAssertNotNil(result.translations[.ko])
        XCTAssertNil(result.translations[.ja])
        XCTAssertTrue(result.failures[.ja]?.contains("authentication failed") == true)
    }

    func testTruncatedTranslationCannotSucceed() throws {
        let first = try SrtDocument(original).cues[0]
        let translator = TranslationEngine(authMethod: .codex, request: { _, _ in ProcessResult(stdout: SrtDocument(cues: [first]).render(), exitCode: 0) })
        let result = translator.translateSrt(srtContent: original, sourceLang: "en", targetLangs: [.ko], onProgress: { _ in })
        XCTAssertTrue(result.translations.isEmpty)
        XCTAssertNotNil(result.failures[.ko])
    }

    func testAllTranslationChunksPreserveTheirEntries() {
        let document = SrtDocument(cues: (1...405).map { SrtDocument.Cue(number: $0, start: Double($0 * 2), end: Double($0 * 2 + 1), text: "Hello") })
        let translator = TranslationEngine(authMethod: .claudeCode, request: { srt, _ in ProcessResult(stdout: srt, exitCode: 0) })
        let result = translator.translateSrt(srtContent: document.render(), sourceLang: "en", targetLangs: [.ko], onProgress: { _ in })
        XCTAssertTrue((try? SrtDocument(result.translations[.ko] ?? "").matchesTiming(of: document)) == true)
    }
}

final class FilePreservationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testAtomicReplacementSucceeds() throws {
        let original = directory.appendingPathComponent("original"), candidate = directory.appendingPathComponent("candidate")
        try Data("original".utf8).write(to: original)
        let snapshot = try SafeFileReplacement.Snapshot(original)
        try Data("new".utf8).write(to: candidate)
        try SafeFileReplacement.replace(original, with: candidate, expected: snapshot)
        XCTAssertEqual(try String(contentsOf: original), "new")
    }

    func testEmptyOutputPreservesOriginal() throws {
        let original = directory.appendingPathComponent("original"), candidate = directory.appendingPathComponent("candidate")
        try Data("original".utf8).write(to: original)
        let snapshot = try SafeFileReplacement.Snapshot(original)
        try Data().write(to: candidate)
        XCTAssertThrowsError(try SafeFileReplacement.replace(original, with: candidate, expected: snapshot))
        XCTAssertEqual(try String(contentsOf: original), "original")
    }

    func testExternalSourceChangePreventsReplacement() throws {
        let original = directory.appendingPathComponent("original"), candidate = directory.appendingPathComponent("candidate")
        try Data("original".utf8).write(to: original)
        let snapshot = try SafeFileReplacement.Snapshot(original)
        try Data("new".utf8).write(to: candidate)
        try Data("edited externally".utf8).write(to: original)
        XCTAssertThrowsError(try SafeFileReplacement.replace(original, with: candidate, expected: snapshot))
        XCTAssertEqual(try String(contentsOf: original), "edited externally")
    }

    func testUnknownLanguageAndThreeLetterSidecarsAreRecognized() throws {
        let media = directory.appendingPathComponent("movie.mp4")
        try Data().write(to: directory.appendingPathComponent("movie.und.srt"))
        try Data().write(to: directory.appendingPathComponent("movie.jpn.srt"))
        XCTAssertEqual(Set(TranscriptionEngine.sidecars(for: media).map { $0.language }), ["und", "ja"])
        XCTAssertEqual(TranscriptionEngine.langCode2("fre"), "fr")
    }

    func testSidecarDoesNotMatchAnotherVideoWithSamePrefix() throws {
        let media = directory.appendingPathComponent("movie.mp4")
        try Data().write(to: directory.appendingPathComponent("movie-extra.en.srt"))
        try Data().write(to: directory.appendingPathComponent("movie.en.srt"))
        try Data().write(to: directory.appendingPathComponent("movie.srt"))
        XCTAssertEqual(Set(TranscriptionEngine.sidecars(for: media).map { $0.url.lastPathComponent }), ["movie.en.srt", "movie.srt"])
    }
}

final class AudioPreparationTests: XCTestCase {
    func testChunkCoverageAndLastDuration() {
        XCTAssertEqual(AudioPreparation.chunks(duration: 3705), [
            .init(start: 0, duration: 1800), .init(start: 1800, duration: 1800), .init(start: 3600, duration: 105)])
        XCTAssertTrue(AudioPreparation.chunks(duration: 0).isEmpty)
    }
    func testShortAudioCanStillDetectLanguage() {
        XCTAssertEqual(AudioPreparation.samples(duration: 3), [.init(start: 0, duration: 3)])
    }
    func testConfidenceIsParsedAndInvalidValuesRejected() {
        let detection = AudioPreparation.detectLanguage("whisper_full_with_state: auto-detected language: ja (p = 0.950000)")
        XCTAssertEqual(detection?.language, "ja")
        XCTAssertEqual(detection?.probability, 0.95)
        XCTAssertNil(AudioPreparation.detectLanguage("auto-detected language: ja (p = nan)"))
    }
}
