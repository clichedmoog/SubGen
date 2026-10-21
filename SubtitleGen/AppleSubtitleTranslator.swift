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
            return ProcessResult(failure: .service(String(localized: "번역할 SRT 형식이 올바르지 않습니다."), retryable: false))
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
            return ProcessResult(failure: .service(String(localized: "Apple 번역 언어 팩이 설치되어 있지 않습니다. 다시 실행하면 다운로드를 요청합니다."), retryable: false))
        case TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage, TranslationError.unsupportedLanguagePairing:
            return ProcessResult(failure: .service(String(localized: "Apple 번역이 이 언어 조합을 지원하지 않습니다. ChatGPT 번역을 사용해주세요."), retryable: false))
        case let missing as AppleTranslationMapping.Missing:
            return ProcessResult(failure: .service(missing.localizedDescription, retryable: true))
        default:
            return ProcessResult(failure: .service(String(localized: "Apple 번역에 실패했습니다: \(error.localizedDescription)"), retryable: true))
        }
    }
}
