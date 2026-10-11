import XCTest
import Security
@testable import SubtitleGen

/// Runs inside the signed, sandboxed app, rather than the SwiftPM test process.
final class SandboxRuntimeTests: XCTestCase {
    func testLoopbackOAuthAndProtectedKeychainInSandbox() async throws {
        let server = ChatGPTLoopback(); let redirect = try await server.start(); defer { server.cancel() }
        XCTAssertEqual(redirect.host, "127.0.0.1")
        let attempt = try ChatGPTOAuth.Attempt(redirect: redirect)
        let callback = URL(string: redirect.absoluteString + "?state=\(attempt.state)&code=test&client_id=oaiapp_sandbox_test")!
        _ = try await URLSession.shared.data(from: callback)
        let received = try await server.callback()
        XCTAssertEqual(try attempt.callback(received).clientID, "oaiapp_sandbox_test")
        let store = ChatGPTKeychain(service: "com.clichedmoog.subtitle-generator.sandbox-test.\(UUID().uuidString)")
        defer { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: store.service] as CFDictionary) }
        let credential = ChatGPTCredentials(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", idToken: "synthetic-identity",
            scopes: [ChatGPTOAuth.planScope], expiresAt: Date().addingTimeInterval(3600))
        let entry = ChatGPTRegistration(id: "oaiapp_sandbox_test", issuer: ChatGPTOAuth.issuer, subject: "synthetic-subject", email: nil, credentials: credential)
        try store.save([entry]); XCTAssertEqual(try store.load().first?.credentials?.refreshToken, "synthetic-refresh")
        var signedOut = entry; signedOut.credentials = nil
        try store.save([signedOut]); XCTAssertNil(try store.load().first?.credentials)
    }
    func testBundledToolsExecuteAndContainerSpeechProducesTimedSubtitles() throws {
        XCTAssertTrue(AppDistribution.isStore)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sandbox-runtime-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let audio = root.appendingPathComponent("speech.wav")
        try ModelDownloader.download(URL(string: "https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.8.4/samples/jfk.wav")!,
                                     to: audio, timeout: 60, cancellation: CancellationToken())
        let model = root.appendingPathComponent("ggml-tiny.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        var tools: [String: String] = [:]
        for name in ["ffmpeg", "ffprobe", "whisper-cli"] {
            let tool = try XCTUnwrap(ToolResolver.find(name), "Bundled \(name) failed its execution probe")
            XCTAssertTrue(tool.hasPrefix(Bundle.main.bundleURL.path + "/Contents/MacOS/"))
            tools[name] = tool
        }
        let info = ProcessRunner.run(tools["ffprobe"]!, arguments: ["-v", "error", "-show_entries", "format=duration", "-of", "json", audio.path], timeout: 20)
        XCTAssertTrue(info.succeeded, info.diagnostic)
        let wav = root.appendingPathComponent("prepared.wav")
        let extracted = ProcessRunner.run(tools["ffmpeg"]!, arguments: ["-y", "-i", audio.path, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path], timeout: 30)
        XCTAssertTrue(extracted.succeeded, extracted.diagnostic)
        var fractions: [Double] = [], messages: [String] = []
        var downloadedBytes: Int64 = 0
        let progressLock = NSLock()
        let engine = TranscriptionEngine()
        let options = TranscriptionEngine.Options(model: model.path, embedSubtitle: false, keepSrtFile: true,
            subtitleDelay: 0, sensitivity: .normal, language: "en", translationTargets: [], authMethod: .codex, translationModel: "")
        let prepared = try engine.prepareSource(file: FileItem(url: audio), whisper: tools["whisper-cli"]!,
            ffmpeg: tools["ffmpeg"]!, ffprobe: tools["ffprobe"]!, options: options, token: CancellationToken(),
            onProgress: { fraction, message in
                progressLock.lock(); defer { progressLock.unlock() }
                fractions.append(fraction); messages.append(message)
            }, onModelDownload: { received, _ in
                progressLock.lock(); defer { progressLock.unlock() }
                downloadedBytes = max(downloadedBytes, received)
            })
        XCTAssertTrue(WhisperModelInstaller.isAvailable(at: model))
        XCTAssertGreaterThan(downloadedBytes, 10_000_000, "Missing model must download before transcription in the sandbox")
        XCTAssertEqual(prepared.language, "en")
        XCTAssertEqual(fractions.last, 1)
        XCTAssertTrue(fractions.contains { $0 > 0 && $0 < 1 }, "Real Whisper timestamps should report partial progress")
        XCTAssertTrue(messages.contains { $0.hasPrefix("전사 ") && $0.contains("청크 1/1") })
        let output = root.appendingPathComponent("output")
        let speech = ProcessRunner.run(tools["whisper-cli"]!, arguments: ["-m", model.path, "-f", wav.path, "-l", "auto", "-osrt", "-of", output.path], timeout: 120)
        XCTAssertTrue(speech.succeeded, speech.diagnostic)
        let document = try SrtDocument(String(contentsOf: output.appendingPathExtension("srt")))
        XCTAssertFalse(document.cues.isEmpty)
        XCTAssertTrue(document.cues.map(\.text).joined(separator: " ").lowercased().contains("country"))
        XCTAssertNotNil(AudioPreparation.detectLanguage(speech.output))
        XCTAssertTrue(speech.output.contains("Metal"), "Exercise the bundled Metal-enabled engine")
    }

    func testStoreStorageUsesTheAppContainer() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        XCTAssertTrue(home.contains("/Library/Containers/"), "Must execute inside a sandboxed app host")
        XCTAssertTrue(AppDistribution.modelDirectory.path.hasPrefix(home + "/"))
        XCTAssertTrue(AppDistribution.logURL.path.hasPrefix(home + "/"))
        XCTAssertNotEqual(AppDistribution.modelDirectory.path, home + "/.cache/whisper-cpp")
        XCTAssertNil(TranslationEngine.findCLI(for: .claudeCode))
        XCTAssertNil(TranslationEngine.findCLI(for: .codex))
    }

    func testSourceBuiltFFmpegCanEmbedAndRecoverSubtitlesInSandbox() throws {
        let ffmpeg = try XCTUnwrap(ToolResolver.find("ffmpeg"))
        let ffprobe = try XCTUnwrap(ToolResolver.find("ffprobe"))
        let license = ProcessRunner.run(ffmpeg, arguments: ["-L"], timeout: 15)
        XCTAssertTrue(license.succeeded, license.diagnostic)
        XCTAssertTrue(license.output.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains("GNU Lesser General Public License"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-embed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base.mp4")
        let generated = ProcessRunner.run(ffmpeg, arguments: ["-v", "error", "-f", "lavfi", "-i", "color=c=black:size=160x90:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "mpeg4", "-c:a", "aac", "-shortest", base.path], timeout: 30)
        XCTAssertTrue(generated.succeeded, generated.diagnostic)
        let engine = TranscriptionEngine()
        let options = TranscriptionEngine.Options(model: "/not-used", embedSubtitle: false, keepSrtFile: true,
            subtitleDelay: 0, sensitivity: .normal, language: "en", translationTargets: [], authMethod: .codex, translationModel: "")
        for ext in ["mp4", "mov", "m4v", "mkv", "webm"] {
            let media = root.appendingPathComponent("sample-\(ext).\(ext)")
            let original = ext == "webm" ? try XCTUnwrap(Bundle(for: Self.self).url(forResource: "video", withExtension: "webm")) : base
            let copied = ProcessRunner.run(ffmpeg, arguments: ["-v", "error", "-i", original.path, "-c", "copy", media.path], timeout: 30)
            XCTAssertTrue(copied.succeeded, copied.diagnostic)
            let srt = root.appendingPathComponent("sample-\(ext).en.srt")
            try "1\n00:00:00,200 --> 00:00:01,500\nSandbox subtitle round trip.\n".write(to: srt, atomically: true, encoding: .utf8)
            XCTAssertTrue(try engine.embed(srt, language: "en", into: media, ffmpeg: ffmpeg, ffprobe: ffprobe, token: CancellationToken()))
            try FileManager.default.removeItem(at: srt)
            let recovered = try engine.prepareSource(file: FileItem(url: media), whisper: "/not-used", ffmpeg: ffmpeg,
                ffprobe: ffprobe, options: options, token: CancellationToken())
            XCTAssertTrue(try String(contentsOf: recovered.url).contains("Sandbox subtitle round trip."), ext)
        }
    }

    func testQueueBookmarksSurviveRecreationAndPreserveOrder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let urls = ["second.wav", "first.wav"].map { root.appendingPathComponent($0) }
        for url in urls { try Data("audio".utf8).write(to: url) }
        let suite = "sandbox-bookmarks-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        autoreleasepool { SandboxFileAccess(defaults: defaults).save(urls) }
        let restored = SandboxFileAccess(defaults: defaults).restore()
        XCTAssertEqual(restored.map(\.path), urls.map(\.path))
        for url in restored { XCTAssertEqual(try Data(contentsOf: url), Data("audio".utf8)) }
        // This validates persistence in the container, not external-folder permission after relaunch.
    }
    func testAppleTranslationPreservesSubtitleStructureWhenLanguagePackInstalled() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Apple Translation requires macOS 26") }
        guard await AppleSubtitleTranslator.status(source: "en", target: .ko) == .installed else {
            throw XCTSkip("English to Korean Apple Translation language pack is not installed")
        }
        let source = "1\n00:00:01,000 --> 00:00:02,500\nGood morning.\n\n2\n00:00:03,000 --> 00:00:04,200\nThe train leaves at noon.\n"
        let translator = try XCTUnwrap(AppleSubtitleTranslator(source: "en", target: .ko))
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: translator.request(source, cancellation: CancellationToken())) }
        }
        XCTAssertTrue(result.succeeded, result.diagnostic)
        let translated = try SrtDocument(result.stdout), original = try SrtDocument(source)
        XCTAssertTrue(translated.matchesTiming(of: original))
        XCTAssertNotEqual(translated.cues.map(\.text), original.cues.map(\.text))
    }
}
