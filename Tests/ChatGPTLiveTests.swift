import XCTest
@testable import SubtitleGen

/// Explicit opt-in only: opens no browser and never reuses another app's credentials.
/// The operator opens the private authorization URL with ego-browser and grants consent.
final class ChatGPTLiveTests: XCTestCase {
    func testAuthorizedAccountCanTranslateTimedSubtitlesAndDisconnect() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SUBGEN_LIVE_CHATGPT_TEST"] == "1",
              let path = environment["SUBGEN_LIVE_AUTH_FILE"], path.hasPrefix("/tmp/") else {
            throw XCTSkip("Requires explicit live-test opt-in and a private /tmp authorization file")
        }
        let file = URL(fileURLWithPath: path)
        let service = ChatGPTAccountService(storage: ChatGPTKeychain(service: "com.clichedmoog.SubGen.live-qa.\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: file) }
        let account = try await service.signIn(accountID: nil, hostID: "urn:uuid:" + UUID().uuidString.lowercased(), consent: true) { url in
            try Data(url.absoluteString.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        do {
            let models = try await service.models(accountID: account, force: true)
            let model = try XCTUnwrap(models.first)
            let source = "1\n00:00:00,000 --> 00:00:02,000\nWelcome to our subtitle test.\n\n2\n00:00:02,500 --> 00:00:04,000\nPlease keep both timestamps unchanged.\n"
            let translated = try await ChatGPTSubtitleClient(accountID: account, model: model.slug, service: service).translate(source, language: .ko)
            let document = try SrtDocument(translated)
            XCTAssertTrue(document.matchesTiming(of: try SrtDocument(source)))
            XCTAssertTrue(document.cues.contains { $0.text.range(of: "[가-힣]", options: .regularExpression) != nil })
            XCTAssertNotEqual(translated, source)
            let revoked = try await service.signOut(accountID: account)
            XCTAssertTrue(revoked, "Local credentials cleared, but OpenAI revocation was not confirmed")
            let accounts = try await service.accounts()
            XCTAssertEqual(accounts.first?.signedIn, false)
        } catch {
            _ = try? await service.signOut(accountID: account)
            throw error
        }
    }
}
