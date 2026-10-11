import XCTest
@testable import SubtitleGen
import Translation

final class AppleTranslationMappingTests: XCTestCase {
    private let source = try! SrtDocument("1\n00:00:01,000 --> 00:00:02,500\nGood morning.\n\n2\n00:00:03,000 --> 00:00:04,200\nThe train\nleaves at noon.\n")

    func testProviderDefaultsAndLabels() {
        XCTAssertEqual(TranslationProvider.allCases, [.chatGPT, .apple])
        XCTAssertEqual(TranslationProvider.apple.label, "Apple 번역 (기기 내)")
        XCTAssertEqual(TranslationProvider(rawValue: "apple"), .apple)
    }

    func testLanguageIdentifiersUseSimplifiedChineseAndRejectUnknownCodes() {
        XCTAssertEqual(AppleTranslationMapping.languageIdentifier(for: "en"), "en")
        XCTAssertEqual(AppleTranslationMapping.languageIdentifier(for: "zh"), "zh-Hans")
        XCTAssertEqual(AppleTranslationMapping.languageIdentifier(for: "KO"), "ko")
        XCTAssertNil(AppleTranslationMapping.languageIdentifier(for: ""))
        XCTAssertNil(AppleTranslationMapping.languageIdentifier(for: "und"))
    }

    func testRequestsUseCueNumbersAndJoinDisplayLines() {
        let requests = AppleTranslationMapping.requests(for: source)
        XCTAssertEqual(requests.map(\.id), ["1", "2"])
        XCTAssertEqual(requests.map(\.text), ["Good morning.", "The train leaves at noon."])
    }

    func testAssemblyKeepsNumbersAndTimingsInAnyResultOrder() throws {
        let translated = try AppleTranslationMapping.assemble(source, translations: ["2": "기차는 정오에 떠납니다.", "1": "좋은 아침입니다."])
        XCTAssertTrue(translated.matchesTiming(of: source))
        XCTAssertEqual(translated.cues.map(\.text), ["좋은 아침입니다.", "기차는 정오에 떠납니다."])
    }

    func testAssemblyNeverWritesBlankLinesIntoSrt() throws {
        let translated = try AppleTranslationMapping.assemble(source, translations: ["1": "좋은\n\n아침", "2": " 정오 \n"])
        XCTAssertEqual(translated.cues.map(\.text), ["좋은 아침", "정오"])
        XCTAssertTrue(try SrtDocument(translated.render()).matchesTiming(of: source))
    }

    func testMissingOrBlankTranslationIsAnError() {
        XCTAssertThrowsError(try AppleTranslationMapping.assemble(source, translations: ["1": "좋은 아침"])) {
            XCTAssertEqual(($0 as? AppleTranslationMapping.Missing)?.cue, 2)
        }
        XCTAssertThrowsError(try AppleTranslationMapping.assemble(source, translations: ["1": "좋은 아침", "2": "  "]))
    }
}

final class AppleSubtitleTranslatorTests: XCTestCase {
    private let srt = "1\n00:00:01,000 --> 00:00:02,500\nGood morning.\n\n2\n00:00:03,000 --> 00:00:04,200\nThe train leaves at noon.\n"

    override func setUpWithError() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Apple Translation adapter requires macOS 26") }
    }

    func testTranslationEngineKeepsNumbersAndTimingsThroughTheAdapter() throws {
        guard #available(macOS 26.0, *) else { return }
        let translator = AppleSubtitleTranslator(batch: { items in
            Dictionary(uniqueKeysWithValues: items.reversed().map { ($0.id, "번역 \($0.id)") })
        })
        let token = CancellationToken()
        let engine = TranslationEngine(authMethod: .codex, cancellation: token, request: { srt, _ in translator.request(srt, cancellation: token) })
        let result = engine.translateSrt(srtContent: srt, sourceLang: "en", targetLangs: [.ko], onProgress: { _ in })
        let translated = try SrtDocument(XCTUnwrap(result.translations[.ko]))
        XCTAssertTrue(translated.matchesTiming(of: try SrtDocument(srt)))
        XCTAssertEqual(translated.cues.map(\.text), ["번역 1", "번역 2"])
    }

    func testMissingLanguagePackAndUnsupportedPairsAreNotRetried() {
        guard #available(macOS 26.0, *) else { return }
        for error in [TranslationError.notInstalled, .unsupportedLanguagePairing, .unsupportedSourceLanguage, .unsupportedTargetLanguage] {
            guard case .service(let message, let retryable) = AppleSubtitleTranslator.result(for: error).failure else { return XCTFail("\(error)") }
            XCTAssertFalse(retryable); XCTAssertTrue(message.contains("Apple 번역"), message)
        }
        guard case .service(_, let retryable) = AppleSubtitleTranslator.result(for: AppleTranslationMapping.Missing(cue: 2)).failure else { return XCTFail() }
        XCTAssertTrue(retryable)
        XCTAssertEqual(AppleSubtitleTranslator.result(for: CancellationError()).failure, .cancelled)
    }

    func testFailedBatchKeepsTranslationFailureVisible() {
        guard #available(macOS 26.0, *) else { return }
        let translator = AppleSubtitleTranslator(batch: { _ in throw TranslationError.notInstalled })
        let token = CancellationToken()
        let engine = TranslationEngine(authMethod: .codex, cancellation: token, request: { srt, _ in translator.request(srt, cancellation: token) })
        let result = engine.translateSrt(srtContent: srt, sourceLang: "en", targetLangs: [.ko], onProgress: { _ in })
        XCTAssertNil(result.translations[.ko]); XCTAssertTrue(result.failures[.ko]?.contains("언어 팩") == true)
    }

    func testCancellationReturnsPromptly() {
        guard #available(macOS 26.0, *) else { return }
        let translator = AppleSubtitleTranslator(batch: { _ in try await Task.sleep(for: .seconds(30)); return [:] })
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel() }
        let started = Date()
        XCTAssertEqual(translator.request(srt, cancellation: token).failure, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }
}

final class StoreTranslatorSelectionTests: XCTestCase {
    private func options(_ provider: TranslationProvider) -> TranscriptionEngine.Options {
        var options = TranscriptionEngine.Options(model: "/unused", embedSubtitle: false, keepSrtFile: true, subtitleDelay: 0,
            sensitivity: .normal, language: "en", translationTargets: [.ko], authMethod: .codex, translationModel: "")
        options.translationProvider = provider
        return options
    }

    func testChatGPTStillRequiresAnAccountButAppleDoesNot() throws {
        let engine = TranscriptionEngine()
        XCTAssertEqual(TranscriptionEngine.Options(model: "", embedSubtitle: false, keepSrtFile: true, subtitleDelay: 0, sensitivity: .normal,
            language: "", translationTargets: [], authMethod: .codex, translationModel: "").translationProvider, .chatGPT)
        XCTAssertThrowsError(try engine.storeTranslator(options: options(.chatGPT), sourceLanguage: "en", token: CancellationToken())) {
            XCTAssertTrue($0.localizedDescription.contains("ChatGPT"))
        }
        if #available(macOS 26.0, *) {
            XCTAssertNoThrow(try engine.storeTranslator(options: options(.apple), sourceLanguage: "en", token: CancellationToken()))
        } else {
            XCTAssertThrowsError(try engine.storeTranslator(options: options(.apple), sourceLanguage: "en", token: CancellationToken()))
        }
    }

    func testUnknownSourceLanguageFailsThatLanguageWithoutRetrying() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Apple Translation requires macOS 26") }
        let translator = try TranscriptionEngine().storeTranslator(options: options(.apple), sourceLanguage: "und", token: CancellationToken())
        var attempts = 0
        let result = translator.translateSrt(srtContent: "1\n00:00:01,000 --> 00:00:02,000\nHello.\n", sourceLang: "und", targetLangs: [.ko],
            onProgress: { if $0.contains("재시도") { attempts += 1 } })
        XCTAssertTrue(result.failures[.ko]?.contains("Apple 번역") == true); XCTAssertEqual(attempts, 0)
    }
}
