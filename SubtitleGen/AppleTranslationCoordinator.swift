import Foundation

enum AppleLanguagePackResult: Equatable {
    case ready
    case failed(String)
}

/// Checks Apple Translation language packs, asks macOS to download missing ones through the window's
/// translation task, and waits for the download. Used before starting and again when an auto-detected
/// source language is only known at translation time.
@MainActor
final class AppleTranslationCoordinator: ObservableObject {
    struct Pair: Hashable { let source: String; let target: TranslationLanguage }
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
    typealias StatusProvider = (String, TranslationLanguage) async -> PairStatus

    @Published private(set) var statuses: [TranslationLanguage: PairStatus] = [:]
    /// Pairs waiting for the system download prompt, shown one at a time.
    @Published private(set) var pendingPairs: [Pair] = []
    @Published private(set) var message: String?
    /// True while a start-time preparation runs; blocks a second start meanwhile.
    @Published private(set) var isPreparing = false
    let isSupported: Bool
    private let status: StatusProvider
    private let pollInterval: Duration
    private let downloadTimeout: Duration
    private var waiters: [Pair: [CheckedContinuation<AppleLanguagePackResult, Never>]] = [:]
    private var downloading: Set<Pair> = []

    init(isSupported: Bool? = nil, pollInterval: Duration = .seconds(2), downloadTimeout: Duration = .seconds(900),
         status: StatusProvider? = nil) {
        if let isSupported { self.isSupported = isSupported }
        else if #available(macOS 26.0, *) { self.isSupported = true } else { self.isSupported = false }
        self.pollInterval = pollInterval
        self.downloadTimeout = downloadTimeout
        self.status = status ?? { source, target in
            guard #available(macOS 26.0, *) else { return .unsupported }
            switch await AppleSubtitleTranslator.status(source: source, target: target) {
            case .installed: return .installed
            case .supported: return .needsDownload
            default: return .unsupported
            }
        }
    }

    func refresh(source: String, targets: Set<TranslationLanguage>) async {
        guard isSupported, !source.isEmpty else { statuses = [:]; return }
        var result: [TranslationLanguage: PairStatus] = [:]
        for target in targets where target.rawValue != source { result[target] = await status(source, target) }
        statuses = result
    }

    /// Start-time check for a known source language. Completion receives true when processing may start;
    /// auto-detected sources are checked per file by `ensureInstalled` instead.
    func prepare(source: String, targets: Set<TranslationLanguage>, completion: @escaping (Bool) -> Void) async {
        guard !isPreparing else { return }
        message = nil
        guard isSupported else { message = Self.unsupportedOS; completion(false); return }
        guard !source.isEmpty else { completion(true); return }
        isPreparing = true
        let finish = { (ready: Bool) in self.isPreparing = false; completion(ready) }
        await refresh(source: source, targets: targets)
        if let unsupported = statuses.first(where: { $0.value == .unsupported })?.key {
            message = Self.unsupportedPair(unsupported); finish(false); return
        }
        for target in statuses.filter({ $0.value == .needsDownload }).keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if case .failed(let failure) = await ensureInstalled(source: source, target: target) {
                message = failure; finish(false); return
            }
        }
        await refresh(source: source, targets: targets)
        finish(true)
    }

    /// Returns once the pack is installed, the download was refused, or it timed out.
    /// Concurrent requests for the same pair share one prompt.
    func ensureInstalled(source: String, target: TranslationLanguage) async -> AppleLanguagePackResult {
        guard isSupported else { return .failed(Self.unsupportedOS) }
        switch await status(source, target) {
        case .installed: return .ready
        case .unsupported: return .failed(Self.unsupportedPair(target))
        case .needsDownload:
            let pair = Pair(source: source, target: target)
            return await withCheckedContinuation { continuation in
                waiters[pair, default: []].append(continuation)
                if !pendingPairs.contains(pair) && !downloading.contains(pair) { pendingPairs.append(pair) }
            }
        }
    }

    /// Called after the system prompt for `pair`. `prepared` is false when the prompt failed or was refused.
    func finishPair(_ pair: Pair, prepared: Bool) {
        pendingPairs.removeAll { $0 == pair }
        guard prepared else {
            resume(pair, .failed("\(pair.target.label) 언어 팩 다운로드가 허용되지 않았습니다. 다시 실행하면 다시 요청합니다."))
            return
        }
        downloading.insert(pair)
        Task {
            let deadline = ContinuousClock.now.advanced(by: downloadTimeout)
            var result = AppleLanguagePackResult.failed("\(pair.target.label) 언어 팩 다운로드가 끝나지 않았습니다. 시스템 설정 > 일반 > 언어 및 지역 > 번역 언어에서 확인한 뒤 다시 실행해주세요.")
            while ContinuousClock.now < deadline {
                if await status(pair.source, pair.target) == .installed { result = .ready; break }
                try? await Task.sleep(for: pollInterval)
            }
            downloading.remove(pair)
            resume(pair, result)
        }
    }

    private func resume(_ pair: Pair, _ result: AppleLanguagePackResult) {
        for continuation in waiters.removeValue(forKey: pair) ?? [] { continuation.resume(returning: result) }
    }

    /// Blocks a translation worker thread until the main-actor check finishes or the file is cancelled.
    nonisolated static func waitForLanguagePack(cancellation: CancellationToken,
                                                _ operation: @escaping @MainActor () async -> AppleLanguagePackResult) -> AppleLanguagePackResult {
        dispatchPrecondition(condition: .notOnQueue(.main))
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var value: AppleLanguagePackResult?
            func set(_ value: AppleLanguagePackResult) { lock.lock(); defer { lock.unlock() }; self.value = value }
            func get() -> AppleLanguagePackResult? { lock.lock(); defer { lock.unlock() }; return value }
        }
        let box = Box(), finished = DispatchSemaphore(value: 0)
        let task = Task { @MainActor in box.set(await operation()); finished.signal() }
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellation.isCancelled { task.cancel(); return .failed("작업이 중단되었습니다") }
        }
        return box.get() ?? .failed("작업이 중단되었습니다")
    }

    private static let unsupportedOS = "Apple 번역은 macOS 26 이상에서 사용할 수 있습니다."
    private static func unsupportedPair(_ target: TranslationLanguage) -> String {
        "Apple 번역이 \(target.label) 번역을 지원하지 않습니다. ChatGPT 번역을 사용하거나 번역 언어를 바꿔주세요."
    }
}
