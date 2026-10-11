import XCTest
@testable import SubtitleGen

@MainActor
final class AppleTranslationCoordinatorTests: XCTestCase {
    private func coordinator(timeout: Duration = .seconds(2), status: @escaping AppleTranslationCoordinator.StatusProvider) -> AppleTranslationCoordinator {
        AppleTranslationCoordinator(isSupported: true, pollInterval: .milliseconds(10), downloadTimeout: timeout, status: status)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testSecondStartWhilePromptIsShowingIsIgnored() async {
        var installed = false
        let coordinator = coordinator { _, _ in installed ? .installed : .needsDownload }
        var first: [Bool] = []
        Task { await coordinator.prepare(source: "en", targets: [.ko]) { first.append($0) } }
        await waitUntil { !coordinator.pendingPairs.isEmpty }
        XCTAssertTrue(coordinator.isPreparing)
        XCTAssertEqual(coordinator.pendingPairs, [.init(source: "en", target: .ko)])
        await coordinator.prepare(source: "en", targets: [.ko, .ja]) { _ in XCTFail("A second start must not replace the pending request") }
        XCTAssertEqual(coordinator.pendingPairs, [.init(source: "en", target: .ko)])
        installed = true
        coordinator.finishPair(.init(source: "en", target: .ko), prepared: true)
        await waitUntil { !first.isEmpty }
        XCTAssertEqual(first, [true]); XCTAssertFalse(coordinator.isPreparing)
    }

    func testAutoDetectedTranslationWaitsForTheDownloadAfterApproval() async {
        var checks = 0
        let coordinator = coordinator { _, _ in
            checks += 1
            return checks >= 4 ? .installed : .needsDownload
        }
        var result: AppleLanguagePackResult?
        Task { result = await coordinator.ensureInstalled(source: "ja", target: .ko) }
        await waitUntil { !coordinator.pendingPairs.isEmpty }
        XCTAssertEqual(coordinator.pendingPairs, [.init(source: "ja", target: .ko)])
        coordinator.finishPair(.init(source: "ja", target: .ko), prepared: true)
        await waitUntil { result != nil }
        XCTAssertEqual(result, .ready)
    }

    func testConcurrentTranslationsShareOnePromptForTheSamePair() async {
        var installed = false
        let coordinator = coordinator { _, _ in installed ? .installed : .needsDownload }
        var results: [AppleLanguagePackResult] = []
        Task { results.append(await coordinator.ensureInstalled(source: "en", target: .ko)) }
        Task { results.append(await coordinator.ensureInstalled(source: "en", target: .ko)) }
        await waitUntil { !coordinator.pendingPairs.isEmpty }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(coordinator.pendingPairs.count, 1)
        installed = true
        coordinator.finishPair(.init(source: "en", target: .ko), prepared: true)
        await waitUntil { results.count == 2 }
        XCTAssertEqual(results, [.ready, .ready])
    }

    func testDeclinedPromptFailsWithoutWaitingForTheTimeout() async {
        let coordinator = coordinator(timeout: .seconds(60)) { _, _ in .needsDownload }
        var result: AppleLanguagePackResult?
        Task { result = await coordinator.ensureInstalled(source: "en", target: .ko) }
        await waitUntil { !coordinator.pendingPairs.isEmpty }
        coordinator.finishPair(.init(source: "en", target: .ko), prepared: false)
        await waitUntil { result != nil }
        guard case .failed(let message) = result else { return XCTFail("Declined download must fail") }
        XCTAssertTrue(message.contains("허용"), message)
    }

    func testDownloadThatNeverFinishesTimesOut() async {
        let coordinator = coordinator(timeout: .milliseconds(50)) { _, _ in .needsDownload }
        var results: [Bool] = []
        Task { await coordinator.prepare(source: "en", targets: [.ko]) { results.append($0) } }
        await waitUntil { !coordinator.pendingPairs.isEmpty }
        coordinator.finishPair(.init(source: "en", target: .ko), prepared: true)
        await waitUntil { !results.isEmpty }
        XCTAssertEqual(results, [false]); XCTAssertTrue(coordinator.message?.contains("언어 팩") == true)
        XCTAssertFalse(coordinator.isPreparing)
    }

    func testUnsupportedPairBlocksStartWithoutPrompt() async {
        let coordinator = coordinator { _, target in target == .ru ? .unsupported : .installed }
        var results: [Bool] = []
        await coordinator.prepare(source: "en", targets: [.ko, .ru]) { results.append($0) }
        XCTAssertEqual(results, [false]); XCTAssertTrue(coordinator.pendingPairs.isEmpty)
        XCTAssertTrue(coordinator.message?.contains("지원하지") == true); XCTAssertFalse(coordinator.isPreparing)
    }

    func testAutoDetectedSourceStartsWithoutPrompt() async {
        let coordinator = coordinator { _, _ in XCTFail("Auto-detected sources are checked when translating"); return .needsDownload }
        var results: [Bool] = []
        await coordinator.prepare(source: "", targets: [.ko]) { results.append($0) }
        XCTAssertEqual(results, [true]); XCTAssertTrue(coordinator.pendingPairs.isEmpty)
    }
}

final class AppleLanguageSettingsLinkTests: XCTestCase {
    func testManageLinkOpensLanguageAndRegionSettings() {
        // Language packs are shared system resources; macOS has no API to remove them, so the app links here.
        let url = AppleTranslationCoordinator.languageSettingsURL
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertEqual(url.absoluteString, "x-apple.systempreferences:com.apple.Localization-Settings.extension")
    }
}

final class AppleLanguagePackBridgeTests: XCTestCase {
    func testWorkerThreadReceivesTheMainActorResult() {
        let done = expectation(description: "bridge returns")
        DispatchQueue.global().async {
            let result = AppleTranslationCoordinator.waitForLanguagePack(cancellation: CancellationToken()) { .ready }
            XCTAssertEqual(result, .ready); done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testCancelledFileStopsWaitingForAPrompt() {
        let token = CancellationToken(), done = expectation(description: "bridge returns")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel() }
        DispatchQueue.global().async {
            let started = Date()
            let result = AppleTranslationCoordinator.waitForLanguagePack(cancellation: token) {
                try? await Task.sleep(for: .seconds(30)); return .ready
            }
            XCTAssertEqual(result, .failed("작업이 중단되었습니다")); XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }
}

final class AppleLanguagePackEngineTests: XCTestCase {
    func testMissingPacksAreRequestedBeforeTranslationAndRefusalsFailOnlyThatLanguage() {
        let engine = TranscriptionEngine()
        var requested: [String] = [], statuses: [String] = []
        engine.appleLanguagePack = { source, target, _ in
            requested.append("\(source)>\(target.rawValue)")
            return target == .ja ? .failed("언어 팩 다운로드가 허용되지 않았습니다.") : .ready
        }
        let prepared = engine.readyAppleTargets([.ko, .ja], source: "en", token: CancellationToken(), onStatus: { statuses.append($0) })
        XCTAssertEqual(requested, ["en>ko", "en>ja"])
        XCTAssertEqual(prepared.ready, [.ko])
        XCTAssertEqual(prepared.failures.count, 1); XCTAssertTrue(prepared.failures[0].contains("일본어"))
        XCTAssertTrue(statuses.contains { $0.contains("언어 팩") && $0.contains("한국어") })
    }

    func testWithoutAPackHandlerTargetsPassThrough() {
        let prepared = TranscriptionEngine().readyAppleTargets([.ko], source: "en", token: CancellationToken(), onStatus: { _ in })
        XCTAssertEqual(prepared.ready, [.ko]); XCTAssertTrue(prepared.failures.isEmpty)
    }
}
