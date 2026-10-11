# Apple 번역 두 번째 번역 방식 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 스토어판에 ChatGPT 다음의 두 번째 번역 방식으로 Apple Translation(기기 내, 계정 불필요)을 추가한다.

**Architecture:** 기존 `TranslationEngine`의 `request: (String, TranslationLanguage) -> ProcessResult` 주입 지점에 Apple 번역 어댑터를 연결한다. 자막 번호·시간은 원문에서 복사하고 문장만 번역하므로 기존 묶음 분할·재시도·`matchesTiming` 검증을 그대로 쓴다. 언어 팩 다운로드는 SwiftUI `.translationTask`의 `prepareTranslation()`으로 처리 시작 전에 받는다.

**Tech Stack:** Swift 5 mode, SwiftUI, Apple Translation framework(macOS 26 API), XCTest(SwiftPM), XcodeGen 스토어 타깃과 샌드박스 런타임 테스트.

**Spec:** `docs/superpowers/specs/2026-10-12-apple-translation-design.md`

## Global Constraints

- 스토어판(`MAC_APP_STORE`)에만 노출한다. 직접 배포 DMG의 Claude Code/Codex 번역 UI·동작은 바꾸지 않는다.
- Apple 번역은 macOS 26 이상. 앱 배포 대상은 macOS 14 그대로이므로 모든 Translation API 사용은 `@available(macOS 26.0, *)` 또는 `#available`로 감싼다.
- Translation.framework는 macOS 14에 없다. 앱 실행 파일이 이 프레임워크를 `LC_LOAD_WEAK_DYLIB`로 링크해야 한다(Task 2에서 검증).
- 기본 번역 방식은 ChatGPT. 설정 키는 `store.translationProvider`.
- UI 문구는 한국어. 라벨: "ChatGPT", "Apple 번역 (기기 내)".
- 자막 텍스트는 기기 밖으로 나가지 않는다. App Privacy 선언과 개인정보 매니페스트는 바꾸지 않는다.
- 기존 ChatGPT 경로와 테스트는 그대로 통과해야 한다.
- 사용자 규칙: 사용자가 요청하기 전에는 커밋·푸시하지 않는다. 각 Task 끝의 "검증" 단계로 커밋을 대신한다.

## Review Focus

1. **macOS 14에서 앱 실행:** Translation.framework가 없는 OS에서도 앱이 실행돼야 한다. → Task 2 Step 6에서 SwiftPM 바이너리, Task 6에서 스토어 앱의 weak link를 `otool`로 확인한다.
2. **번역 결과에 빈 줄·줄바꿈이 들어오는 경우:** SRT 블록이 깨지면 안 된다(빈 줄은 블록 구분자). → Task 1 `assemble` 테스트가 줄바꿈을 공백으로 바꾸는지 고정한다.
3. **일부 자막이 결과에서 빠지거나 빈 문자열인 경우:** 빈 자막을 저장하지 말고 재시도 가능한 실패로 처리해야 한다. → Task 1 `assemble` 누락·빈 결과 테스트, Task 2 오류 대응 테스트.
4. **자동 감지된 원본 언어를 Apple이 지원하지 않는 경우(예: `tl`):** 그 언어만 실패하고 안내 문구가 나와야 하며 재시도로 시간을 끌지 않아야 한다. → Task 2 `result(for:)`가 미지원·미설치 오류를 `retryable: false`로 내는지 테스트.
5. **번역 도중 취소:** 대기 없이 `.cancelled`로 돌아와야 한다. → Task 2에서 오래 걸리는 가짜 번역 함수에 취소를 보내 1초 안에 끝나는지 테스트.

---

### Task 1: 번역 방식 열거형과 프레임워크 비의존 매핑

**Files:**
- Modify: `SubtitleGen/Models.swift` (`TranslationLanguage` 정의 바로 아래)
- Create: `SubtitleGen/AppleTranslationMapping.swift`
- Test: `Tests/AppleTranslationTests.swift`

**Interfaces:**
- Produces:
  - `enum TranslationProvider: String, CaseIterable, Identifiable { case chatGPT, apple; var label: String }`
  - `enum AppleTranslationMapping`
    - `static func languageIdentifier(for code: String) -> String?`
    - `static func requests(for document: SrtDocument) -> [(id: String, text: String)]`
    - `static func assemble(_ document: SrtDocument, translations: [String: String]) throws -> SrtDocument`
    - `struct Missing: LocalizedError { let cue: Int }`

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/AppleTranslationTests.swift`

```swift
import XCTest
@testable import SubtitleGen

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
```

- [ ] **Step 2: 실패 확인**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | sort -u | head`
Expected: `cannot find 'TranslationProvider' in scope`, `cannot find 'AppleTranslationMapping' in scope`

- [ ] **Step 3: 구현** — `SubtitleGen/Models.swift`의 `enum TranslationLanguage { ... }` 닫는 중괄호 바로 아래에 추가

```swift
/// Store translation backends. ChatGPT stays first; Apple Translation needs no account.
enum TranslationProvider: String, CaseIterable, Identifiable {
    case chatGPT, apple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .apple: return "Apple 번역 (기기 내)"
        }
    }
}
```

`SubtitleGen/AppleTranslationMapping.swift` 생성:

```swift
import Foundation

/// Framework-independent parts of Apple Translation support. Subtitle numbers and timings
/// are copied from the source and never pass through the translator.
enum AppleTranslationMapping {
    struct Missing: LocalizedError {
        let cue: Int
        var errorDescription: String? { "Apple 번역 결과에 \(cue)번 자막이 없습니다." }
    }

    /// Whisper/SRT two-letter codes to identifiers understood by the Translation framework.
    static func languageIdentifier(for code: String) -> String? {
        let code = code.lowercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return code == "zh" ? "zh-Hans" : code
    }

    static func requests(for document: SrtDocument) -> [(id: String, text: String)] {
        document.cues.map { (String($0.number), singleLine($0.text)) }
    }

    static func assemble(_ document: SrtDocument, translations: [String: String]) throws -> SrtDocument {
        SrtDocument(cues: try document.cues.map { cue in
            let text = singleLine(translations[String(cue.number)] ?? "")
            guard !text.isEmpty else { throw Missing(cue: cue.number) }
            return SrtDocument.Cue(number: cue.number, start: cue.start, end: cue.end, text: text)
        })
    }

    /// Display line breaks are not meaningful to the translator, and a blank line would split an SRT block.
    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift build --build-tests 2>&1 | grep error: ; swift test --skip-build --filter AppleTranslationMappingTests 2>&1 | grep -E "failed|Executed" | tail -2`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: 검증** — `swift test 2>&1 | grep -E "failed|Executed .* tests" | tail -2` 결과가 실패 0인지 확인(커밋하지 않음).

---

### Task 2: Apple Translation 어댑터

**Files:**
- Create: `SubtitleGen/AppleSubtitleTranslator.swift`
- Test: `Tests/AppleTranslationTests.swift` (클래스 추가)

**Interfaces:**
- Consumes: `AppleTranslationMapping` (Task 1), `ProcessResult`, `CancellationToken`, `TranslationEngine(authMethod:cancellation:request:)`
- Produces (`@available(macOS 26.0, *) struct AppleSubtitleTranslator`):
  - `typealias Batch = ([(id: String, text: String)]) async throws -> [String: String]`
  - `init(batch: @escaping Batch)` (테스트용)
  - `init?(source: String, target: TranslationLanguage)` (실제 세션, 설치된 언어 팩 사용)
  - `func request(_ srt: String, cancellation: CancellationToken) -> ProcessResult`
  - `static func result(for error: Error) -> ProcessResult`
  - `static func status(source: String, target: TranslationLanguage) async -> LanguageAvailability.Status`

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/AppleTranslationTests.swift` 맨 위 `@testable import SubtitleGen` 아래에 `import Translation`을 추가하고, 파일 맨 아래에 다음 클래스를 추가

```swift
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
```

- [ ] **Step 2: 실패 확인**

Run: `swift build --build-tests 2>&1 | grep -E "error:" | sort -u | head`
Expected: `cannot find 'AppleSubtitleTranslator' in scope`

- [ ] **Step 3: 구현** — `SubtitleGen/AppleSubtitleTranslator.swift`

```swift
import Foundation
import Translation

/// Store translation backend using Apple's on-device Translation framework.
@available(macOS 26.0, *)
struct AppleSubtitleTranslator {
    typealias Batch = ([(id: String, text: String)]) async throws -> [String: String]
    let batch: Batch

    init(batch: @escaping Batch) { self.batch = batch }

    /// Uses installed language packs; downloads go through the app's preparation UI.
    init?(source: String, target: TranslationLanguage) {
        guard let sourceID = AppleTranslationMapping.languageIdentifier(for: source),
              let targetID = AppleTranslationMapping.languageIdentifier(for: target.rawValue) else { return nil }
        let sourceLanguage = Locale.Language(identifier: sourceID), targetLanguage = Locale.Language(identifier: targetID)
        batch = { items in
            let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
            let requests = items.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
            let responses = try await withTaskCancellationHandler {
                try await session.translations(from: requests)
            } onCancel: { session.cancel() }
            return Dictionary(responses.compactMap { response in response.clientIdentifier.map { ($0, response.targetText) } },
                              uniquingKeysWith: { first, _ in first })
        }
    }

    static func status(source: String, target: TranslationLanguage) async -> LanguageAvailability.Status {
        guard let sourceID = AppleTranslationMapping.languageIdentifier(for: source),
              let targetID = AppleTranslationMapping.languageIdentifier(for: target.rawValue) else { return .unsupported }
        return await LanguageAvailability().status(from: Locale.Language(identifier: sourceID), to: Locale.Language(identifier: targetID))
    }

    /// Called on the translation operation queue, like ChatGPTSubtitleClient.request.
    func request(_ srt: String, cancellation: CancellationToken) -> ProcessResult {
        if cancellation.isCancelled { return ProcessResult(failure: .cancelled) }
        guard let document = try? SrtDocument(srt) else {
            return ProcessResult(failure: .service("번역할 SRT 형식이 올바르지 않습니다.", retryable: false))
        }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var value: ProcessResult?
            func set(_ value: ProcessResult) { lock.lock(); defer { lock.unlock() }; self.value = value }
            func get() -> ProcessResult? { lock.lock(); defer { lock.unlock() }; return value }
        }
        let box = Box(), finished = DispatchSemaphore(value: 0), batch = self.batch
        let task = Task {
            defer { finished.signal() }
            do {
                let translated = try await batch(AppleTranslationMapping.requests(for: document))
                box.set(ProcessResult(stdout: try AppleTranslationMapping.assemble(document, translations: translated).render(), exitCode: 0))
            } catch { box.set(Self.result(for: error)) }
        }
        let deadline = Date().addingTimeInterval(600)
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellation.isCancelled { task.cancel(); return ProcessResult(failure: .cancelled) }
            if Date() >= deadline { task.cancel(); return ProcessResult(failure: .timedOut) }
        }
        return cancellation.isCancelled ? ProcessResult(failure: .cancelled) : box.get() ?? ProcessResult(failure: .cancelled)
    }

    static func result(for error: Error) -> ProcessResult {
        switch error {
        case is CancellationError, TranslationError.alreadyCancelled:
            return ProcessResult(failure: .cancelled)
        case TranslationError.notInstalled:
            return ProcessResult(failure: .service("Apple 번역 언어 팩이 설치되어 있지 않습니다. 작업 설정에서 원본 언어를 지정하고 '언어 팩 준비'를 누른 뒤 다시 실행해주세요.", retryable: false))
        case TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage, TranslationError.unsupportedLanguagePairing:
            return ProcessResult(failure: .service("Apple 번역이 이 언어 조합을 지원하지 않습니다. ChatGPT 번역을 사용해주세요.", retryable: false))
        case let missing as AppleTranslationMapping.Missing:
            return ProcessResult(failure: .service(missing.localizedDescription, retryable: true))
        default:
            return ProcessResult(failure: .service("Apple 번역에 실패했습니다: \(error.localizedDescription)", retryable: true))
        }
    }
}
```

참고: `TranslationSession(installedSource:target:)`가 MainActor 격리 등으로 컴파일 오류를 내면 컴파일러 메시지를 따라 `batch` 클로저 안에서 `await MainActor.run`으로 세션을 만들도록 고친다. API 이름은 SDK `Translation.swiftinterface`(MacOSX27.0.sdk)에서 확인한 것이다.

- [ ] **Step 4: 통과 확인**

Run: `swift build --build-tests 2>&1 | grep error: ; swift test --skip-build --filter "AppleSubtitleTranslatorTests|AppleTranslationMappingTests" 2>&1 | grep -E "failed|Executed" | tail -2`
Expected: `Executed 10 tests, with 0 failures`

- [ ] **Step 5: 전체 회귀** — `swift test 2>&1 | grep -E "failed|Executed .* tests" | tail -2` 실패 0.

- [ ] **Step 6: weak link 확인 (Review Focus 1)**

Run: `B=$(swift build --show-bin-path)/SubGen; otool -l "$B" | grep -B1 -A3 Translation.framework | grep -E "cmd LC_LOAD|name"`
Expected: `cmd LC_LOAD_WEAK_DYLIB` 와 `.../Translation.framework/...`
`LC_LOAD_DYLIB`(strong)이면 `Package.swift`의 `executableTarget`에 `linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "Translation"])]`를 추가하고 다시 확인한다.

---

### Task 3: 엔진에서 번역 방식 선택

**Files:**
- Modify: `SubtitleGen/TranscriptionEngine.swift` (`struct Options`, 번역 분기 `if AppDistribution.isStore { ... }`)
- Test: `Tests/AppleTranslationTests.swift` (클래스 추가)

**Interfaces:**
- Consumes: `TranslationProvider` (Task 1), `AppleSubtitleTranslator` (Task 2)
- Produces:
  - `TranscriptionEngine.Options.translationProvider: TranslationProvider` (기본 `.chatGPT`)
  - `func storeTranslator(options: Options, sourceLanguage: String, token: CancellationToken) throws -> TranslationEngine`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
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
```

- [ ] **Step 2: 실패 확인** — `swift build --build-tests 2>&1 | grep error: | sort -u` → `value of type 'TranscriptionEngine.Options' has no member 'translationProvider'`, `has no member 'storeTranslator'`

- [ ] **Step 3: 구현**

`struct Options`의 마지막 줄 `var chatGPTModel: String? = nil` 아래에 추가:

```swift
        var translationProvider: TranslationProvider = .chatGPT
```

번역 분기 교체 — 기존:

```swift
                if AppDistribution.isStore {
                    guard let account = options.chatGPTAccountID, let model = options.chatGPTModel else {
                        throw PipelineFailure("번역할 ChatGPT 계정과 모델을 선택해주세요.")
                    }
                    let client = ChatGPTSubtitleClient(accountID: account, model: model)
                    translator = TranslationEngine(authMethod: options.authMethod, cancellation: token,
                        request: { client.request($0, language: $1, cancellation: token) })
                } else {
```

새 코드:

```swift
                if AppDistribution.isStore {
                    translator = try storeTranslator(options: options, sourceLanguage: source.language, token: token)
                } else {
```

같은 파일의 `struct Options` 정의 바로 위에 메서드 추가:

```swift
    /// External CLIs are disabled in the sandboxed app; ChatGPT or Apple Translation translate instead.
    func storeTranslator(options: Options, sourceLanguage: String, token: CancellationToken) throws -> TranslationEngine {
        switch options.translationProvider {
        case .apple:
            guard #available(macOS 26.0, *) else { throw PipelineFailure("Apple 번역은 macOS 26 이상에서 사용할 수 있습니다.") }
            return TranslationEngine(authMethod: options.authMethod, cancellation: token, request: { srt, language in
                guard let translator = AppleSubtitleTranslator(source: sourceLanguage, target: language) else {
                    return ProcessResult(failure: .service("Apple 번역이 이 언어 조합을 지원하지 않습니다. ChatGPT 번역을 사용해주세요.", retryable: false))
                }
                return translator.request(srt, cancellation: token)
            })
        case .chatGPT:
            guard let account = options.chatGPTAccountID, let model = options.chatGPTModel else {
                throw PipelineFailure("번역할 ChatGPT 계정과 모델을 선택해주세요.")
            }
            let client = ChatGPTSubtitleClient(accountID: account, model: model)
            return TranslationEngine(authMethod: options.authMethod, cancellation: token,
                request: { client.request($0, language: $1, cancellation: token) })
        }
    }
```

- [ ] **Step 4: 통과 확인** — `swift test --filter "StoreTranslatorSelectionTests" 2>&1 | grep -E "failed|Executed" | tail -1` → 실패 0
- [ ] **Step 5: 전체 회귀** — `swift test 2>&1 | grep -E "failed|Executed .* tests" | tail -2` 실패 0.

---

### Task 4: 스토어판 화면 — 번역 방식 선택과 언어 팩 준비

**Files:**
- Create: `SubtitleGen/AppleTranslationOptions.swift` (파일 전체 `#if MAC_APP_STORE`)
- Modify: `SubtitleGen/ContentView.swift` — 상태 선언(33–35행 `#if MAC_APP_STORE` 블록), `body` 루트 수식어(63–80행), `startProcessing()`(882행 부근), `chatGPTOptions`(929행 부근)

**Interfaces:**
- Consumes: `AppleSubtitleTranslator.status(source:target:)`, `AppleTranslationMapping.languageIdentifier(for:)`, `TranslationProvider`, `Options.translationProvider`
- Produces:
  - `@MainActor final class AppleTranslationCoordinator: ObservableObject` — `statuses`, `pendingPairs`, `message`, `static var isSupported`, `func refresh(source:targets:) async`, `func prepare(source:targets:completion:) async`, `func finishPair()`
  - `struct AppleTranslationOptionsView: View`, `@available(macOS 26.0, *) struct AppleTranslationPreparationHost: View`

- [ ] **Step 1: `SubtitleGen/AppleTranslationOptions.swift` 생성**

```swift
#if MAC_APP_STORE
import SwiftUI
import Translation

/// Checks Apple Translation language packs and asks macOS to download missing ones before processing.
@MainActor
final class AppleTranslationCoordinator: ObservableObject {
    struct Pair: Hashable { let source: String; let target: String }
    enum PairStatus: Equatable {
        case installed, needsDownload, unsupported
        var label: String {
            switch self {
            case .installed: return "설치됨"
            case .needsDownload: return "다운로드 필요"
            case .unsupported: return "지원 안 함"
            }
        }
    }

    @Published private(set) var statuses: [TranslationLanguage: PairStatus] = [:]
    @Published private(set) var pendingPairs: [Pair] = []
    @Published private(set) var message: String?
    private var completion: ((Bool) -> Void)?
    private var request: (source: String, targets: Set<TranslationLanguage>)?

    static var isSupported: Bool { if #available(macOS 26.0, *) { return true } else { return false } }

    func refresh(source: String, targets: Set<TranslationLanguage>) async {
        guard #available(macOS 26.0, *), !source.isEmpty else { statuses = [:]; return }
        var result: [TranslationLanguage: PairStatus] = [:]
        for target in targets where target.rawValue != source {
            switch await AppleSubtitleTranslator.status(source: source, target: target) {
            case .installed: result[target] = .installed
            case .supported: result[target] = .needsDownload
            default: result[target] = .unsupported
            }
        }
        statuses = result
    }

    /// Completion receives true when processing may start. Auto-detected sources are checked per file later.
    func prepare(source: String, targets: Set<TranslationLanguage>, completion: @escaping (Bool) -> Void) async {
        message = nil
        guard Self.isSupported else { message = "Apple 번역은 macOS 26 이상에서 사용할 수 있습니다."; completion(false); return }
        guard !source.isEmpty else { completion(true); return }
        await refresh(source: source, targets: targets)
        if let unsupported = statuses.first(where: { $0.value == .unsupported })?.key {
            message = "Apple 번역이 \(unsupported.label) 번역을 지원하지 않습니다. ChatGPT 번역을 사용하거나 번역 언어를 바꿔주세요."
            completion(false); return
        }
        let missing = statuses.filter { $0.value == .needsDownload }.keys.sorted { $0.rawValue < $1.rawValue }
        guard !missing.isEmpty, let sourceID = AppleTranslationMapping.languageIdentifier(for: source) else { completion(true); return }
        self.completion = completion
        request = (source, targets)
        pendingPairs = missing.compactMap { target in AppleTranslationMapping.languageIdentifier(for: target.rawValue).map { Pair(source: sourceID, target: $0) } }
    }

    func finishPair() {
        if !pendingPairs.isEmpty { pendingPairs.removeFirst() }
        guard pendingPairs.isEmpty, let request else { return }
        self.request = nil
        Task {
            await refresh(source: request.source, targets: request.targets)
            let ready = !statuses.values.contains { $0 != .installed }
            if !ready { message = "언어 팩 다운로드가 완료되지 않았습니다. 다시 시도하거나 시스템 설정 > 일반 > 언어 및 지역 > 번역 언어에서 받아주세요." }
            let completion = self.completion
            self.completion = nil
            completion?(ready)
        }
    }
}

/// Invisible host whose translation task shows the system download confirmation.
@available(macOS 26.0, *)
struct AppleTranslationPreparationHost: View {
    @ObservedObject var coordinator: AppleTranslationCoordinator
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                do { try await session.prepareTranslation() }
                catch { logDebug("Apple translation preparation: \(error.localizedDescription)") }
                await MainActor.run { configuration = nil; coordinator.finishPair() }
            }
            .onChange(of: coordinator.pendingPairs) { _, pairs in
                guard configuration == nil, let pair = pairs.first else { return }
                configuration = .init(source: Locale.Language(identifier: pair.source), target: Locale.Language(identifier: pair.target))
            }
    }
}

struct AppleTranslationOptionsView: View {
    @ObservedObject var coordinator: AppleTranslationCoordinator
    let source: String
    let targets: Set<TranslationLanguage>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !AppleTranslationCoordinator.isSupported {
                Text("Apple 번역은 macOS 26 이상에서 사용할 수 있습니다.").font(.caption).foregroundStyle(.red)
            } else {
                Text("계정 없이 이 Mac에서 번역합니다. 자막이 외부로 전송되지 않습니다.").font(.caption).foregroundStyle(.secondary)
                if source.isEmpty {
                    Text("자동 감지된 언어의 언어 팩이 없으면 그 번역은 실패합니다. 원본 언어를 지정하면 미리 준비할 수 있습니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if !targets.isEmpty {
                    ForEach(targets.sorted { $0.rawValue < $1.rawValue }) { target in
                        if let status = coordinator.statuses[target] {
                            Text("\(target.label) 언어 팩: \(status.label)").font(.caption2)
                        }
                    }
                    Button("언어 팩 준비") { Task { await coordinator.prepare(source: source, targets: targets) { _ in } } }
                        .controlSize(.small).disabled(!coordinator.pendingPairs.isEmpty)
                }
                if let message = coordinator.message {
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .task(id: "\(source)|\(targets.map(\.rawValue).sorted().joined(separator: ","))") {
            await coordinator.refresh(source: source, targets: targets)
        }
    }
}
#endif
```

- [ ] **Step 2: `ContentView` 상태 추가** — 33–35행의 `#if MAC_APP_STORE` 블록(`@StateObject private var chatGPT = ...`)에 추가

```swift
    @AppStorage("store.translationProvider") private var translationProvider: TranslationProvider = .chatGPT
    @StateObject private var appleTranslation = AppleTranslationCoordinator()
```

- [ ] **Step 3: 루트 수식어에 준비 호스트 연결** — `body`의 `.sheet(isPresented: $showSetup) { setupSection }` 바로 위에 추가

```swift
        #if MAC_APP_STORE
        .background {
            if #available(macOS 26.0, *) { AppleTranslationPreparationHost(coordinator: appleTranslation) }
        }
        .onChange(of: translationProvider) { _, _ in requeueForChangedOptions() }
        #endif
```

- [ ] **Step 4: `startProcessing` 게이트 교체** — 시그니처와 첫 `#if MAC_APP_STORE` 블록을 다음으로 바꾼다.

기존:

```swift
    private func startProcessing() {
        #if MAC_APP_STORE
        if !selectedTranslations.isEmpty && !chatGPT.canTranslate {
            engine.currentStatus = "번역하려면 ChatGPT 로그인·플랜 사용 권한·모델 선택을 확인해주세요."
            return
        }
        #endif
```

새 코드:

```swift
    private func startProcessing(applePrepared: Bool = false) {
        #if MAC_APP_STORE
        if !selectedTranslations.isEmpty {
            switch translationProvider {
            case .chatGPT where !chatGPT.canTranslate:
                engine.currentStatus = "번역하려면 ChatGPT 로그인·플랜 사용 권한·모델 선택을 확인해주세요."
                return
            case .apple where !applePrepared:
                engine.currentStatus = "Apple 번역 언어 팩 확인 중..."
                Task {
                    await appleTranslation.prepare(source: language.rawValue, targets: selectedTranslations) { ready in
                        if ready { startProcessing(applePrepared: true) }
                        else { engine.currentStatus = appleTranslation.message ?? "Apple 번역을 준비하지 못했습니다." }
                    }
                }
                return
            default: break
            }
        }
        #endif
```

그리고 같은 함수의 두 번째 `#if MAC_APP_STORE` 블록(`options.chatGPTAccountID = ...`)에 한 줄 추가:

```swift
        options.translationProvider = translationProvider
```

`startProcessing()`을 버튼 등에서 인자 없이 부르는 기존 호출은 기본값 덕분에 그대로 둔다.

- [ ] **Step 5: `chatGPTOptions` 상단에 선택기와 분기 추가** — `VStack(alignment: .leading, spacing: 8) {` 바로 다음 줄에 선택기를 넣고, 기존 ChatGPT 계정·로그인·모델·오류 UI(첫 `if !chatGPT.accounts.isEmpty`부터 `if let error = chatGPT.error { ... }`까지)를 `if translationProvider == .chatGPT { ... } else { AppleTranslationOptionsView(...) }`로 감싼다.

```swift
            Picker("번역 방식", selection: $translationProvider) {
                ForEach(TranslationProvider.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if translationProvider == .chatGPT {
                // 기존 ChatGPT UI 블록 그대로
            } else {
                AppleTranslationOptionsView(coordinator: appleTranslation, source: language.rawValue, targets: selectedTranslations)
            }
```

목록 아래 안내 문구를 번역 방식에 맞게 바꾼다:

```swift
            Text(translationProvider == .apple ? "번역 언어를 선택하지 않으면 전사만 합니다." : "번역 언어를 선택하지 않으면 로그인 없이 전사할 수 있습니다.")
                .font(.caption2).foregroundStyle(.secondary)
```

- [ ] **Step 6: 스토어 타깃 빌드 확인**

Run: `xcodegen generate --quiet && xcodebuild -project SubGen.xcodeproj -scheme SubGen -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$TMPDIR/subgen-apple-ui" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: SwiftPM(DMG판) 영향 없음 확인** — `swift build 2>&1 | grep -E "error:|Compiling|Build complete" | tail -2` 성공, `swift test` 실패 0.

---

### Task 5: 실제 Apple 번역 샌드박스 시험과 스토어 자료

**Files:**
- Modify: `Store/Tests/SandboxRuntimeTests.swift` (테스트 1개 추가)
- Modify: `Store/store.config.json` (`review.notes`)
- Modify: `Store/testflight-what-to-test.en-US.txt`
- Modify: `docs/privacy.md` (영어·한국어 각 1문장)

**Interfaces:**
- Consumes: `AppleSubtitleTranslator(source:target:)`, `AppleSubtitleTranslator.status(source:target:)`

- [ ] **Step 1: 런타임 테스트 추가** — `SandboxRuntimeTests` 클래스 안에

```swift
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
```

- [ ] **Step 2: 샌드박스 런타임 테스트 실행**

Run: `xcodebuild -project SubGen.xcodeproj -scheme SubGen -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$TMPDIR/subgen-runtime" PRODUCT_BUNDLE_IDENTIFIER=com.clichedmoog.subtitle-generator.store-qa CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Development' test 2>&1 | grep -E "Test Case.*(passed|failed|skipped)|\*\* TEST"`
Expected: 기존 5개 통과, 새 테스트는 통과 또는 언어 팩 미설치로 `skipped`. 건너뛰었다면 시스템 설정 > 일반 > 언어 및 지역 > 번역 언어에서 영어·한국어를 받은 뒤 다시 실행해 실제 통과를 기록한다(사용자 확인 필요).

- [ ] **Step 3: 심사 메모 갱신** — `Store/store.config.json`의 `review.notes`에서 `OPTIONAL TRANSLATION\n...`부터 `usage limits.` 문단 끝까지를 다음으로 교체(Python `json` 모듈로 수정해 서식을 보존)

```text
OPTIONAL TRANSLATION (no account needed)
On macOS 26 or later, expand 작업 설정, choose 번역 방식 → Apple 번역 (기기 내), set the spoken language (for example English), check a target language such as 한국어, then click 처리 시작. If macOS asks to download translation languages, approve it. Translation runs on the Mac with Apple's Translation framework; subtitles are not sent to the developer or any translation service.

Alternatively choose ChatGPT and click Continue with ChatGPT. This opens OpenAI authorization and asks for consent to use an eligible ChatGPT account's plan/credits. Only subtitle text and translation instructions are sent to OpenAI. This option is subject to OpenAI account eligibility, availability and usage limits.
```

- [ ] **Step 4: TestFlight 안내 갱신** — `Store/testflight-what-to-test.en-US.txt`의 `5. Continue with ChatGPT` 줄 앞에 새 항목을 넣고 이후 번호를 하나씩 민다

```text
5. Apple Translation (new in build 6, macOS 26+): choose 번역 방식 → Apple 번역 (기기 내), set the spoken language, select a target language and start. Approve the macOS download prompt if shown. Translated SRT numbering and timings must match the source. With automatic language detection, a missing language pack should fail only that translation and keep the source subtitles.
```

- [ ] **Step 5: 개인정보 문서** — `docs/privacy.md`의 영어 `### Optional ChatGPT translation` 섹션 첫 문단 끝에 추가: `On macOS 26 or later you can instead choose Apple Translation, which translates subtitles on your Mac with Apple's Translation framework; SubGen does not send subtitle text anywhere for that option.` 한국어 번역 섹션 첫 문단 끝에 추가: `macOS 26 이상에서는 Apple 번역을 선택할 수 있으며, 이 경우 Apple Translation 프레임워크로 Mac에서 번역하고 SubGen은 자막 텍스트를 외부로 보내지 않습니다.` 상단 `Last updated` 날짜를 `October 12, 2026`으로 바꾼다. (공개 URL 반영은 GitHub 게시 단계에서 별도로 한다.)

- [ ] **Step 6: Store 스크립트 검증** — `python3 -m unittest discover -s Store/scripts -p 'test_*.py' 2>&1 | tail -2` → `OK`

---

### Task 6: 빌드 1.0 (6) 패키지와 TestFlight

**Files:**
- Modify: `project.yml` (`CURRENT_PROJECT_VERSION: "6"`), `Store/store.config.json` (`macAppStore.build`, `delivery`, 근거), `Store/releases/2026-10-12.md`, `TODO.md`

- [ ] **Step 1: 빌드 번호 6** — `project.yml`의 `CURRENT_PROJECT_VERSION: "5"` → `"6"`, `store.config.json`의 `macAppStore.build` → `"6"`(json 모듈), `xcodegen generate --quiet`, `python3 scripts/prepare-store-tools.py`
- [ ] **Step 2: 아카이브·검사·export·패키지 검증**

```bash
R=build/subgen-release-20261012
xcodebuild -project SubGen.xcodeproj -scheme SubGen -configuration Release -destination 'generic/platform=macOS' -archivePath $R/SubGen-1.0-6.xcarchive -derivedDataPath $R/DerivedData6 -allowProvisioningUpdates archive > $R/archive6.log 2>&1
python3 Store/scripts/store.py inspect $R/SubGen-1.0-6.xcarchive --channel app-store > $R/archive6-inspection.json
xcodebuild -exportArchive -archivePath $R/SubGen-1.0-6.xcarchive -exportOptionsPlist $R/ExportOptions.plist -exportPath $R/export6 -allowProvisioningUpdates > $R/export6.log 2>&1
python3 Store/scripts/verify-testflight-package.py $R/export6/SubGen.pkg > $R/package6-verification.json
shasum -a 256 $R/export6/SubGen.pkg
```

Expected: `ARCHIVE SUCCEEDED`, `EXPORT SUCCEEDED`, 검증 JSON `verification`이 `Mac App Store package/signing/profile/helpers/source verified`, 식별자 1.0 (6).

- [ ] **Step 3: 스토어 앱 weak link 확인 (Review Focus 1)** — `otool -l "$R/SubGen-1.0-6.xcarchive/Products/Applications/SubGen.app/Contents/MacOS/SubGen" | grep -B1 -A3 Translation.framework | grep cmd` → `LC_LOAD_WEAK_DYLIB`. strong이면 `project.yml` 타깃 `settings.base`에 `OTHER_LDFLAGS: ["$(inherited)", "-weak_framework", "Translation"]`를 추가하고 Step 2부터 다시.
- [ ] **Step 4: 업로드와 TestFlight** — `apple-app-submit` 스킬의 기존 API 키 절차(앱 6820884731 접근 재확인)로 `altool --validate-app` → `--upload-package --wait`. 공식 API로 빌드 6 `VALID`, 내부 그룹 `IN_BETA_TESTING`, en-US What to Test 저장·일치 확인, App Store 버전 1.0 선택 빌드를 6으로 변경·확인(`AFTER_APPROVAL` 유지).
- [ ] **Step 5: 기록** — `store.config.json`(`delivery`를 빌드 6으로, 이전 값은 `previousDeliveryBuild5`), `Store/releases/2026-10-12.md`에 Apple 번역 절, `TODO.md` 체크. 사용자가 이 Mac에서 1.0 (6) 설치 후 Apple 번역·ChatGPT 번역을 확인하기 전에는 `releaseRuntimeVerified`·`translationBackendVerified`를 바꾸지 않는다. 정식 심사 제출은 그 확인 뒤 별도 단계.
