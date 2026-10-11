import XCTest
@testable import SubtitleGen

final class TranslationModelTests: XCTestCase {
    private let source = "1\n00:00:01,000 --> 00:00:03,000\nWe need to break the ice.\n\n2\n00:00:04,000 --> 00:00:06,000\nLet's get started.\n"
    private let translated = "1\n00:00:01,000 --> 00:00:03,000\n어색한 분위기를 풀어야 해요.\n\n2\n00:00:04,000 --> 00:00:06,000\n시작합시다.\n"

    func testDatedPreferencesKeepTheirModelFamily() {
        for (old, expected) in [
            ("claude-opus-4-6[1m]", TranslationModel.claudeOpus),
            ("claude-opus-4-20250514", .claudeOpus),
            ("claude-sonnet-4-20250514", .claudeSonnet),
            ("claude-haiku-4-5-20251001", .claudeHaiku)
        ] {
            XCTAssertEqual(TranslationModel.resolve(old, for: .claudeCode), expected)
        }
    }

    func testPreferencesMigrationIsIdempotentAndProviderAware() {
        let suite = "TranslationModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("claude-sonnet-4-20250514", forKey: "translationModel")
        TranslationModel.migratePreferences(in: defaults)
        XCTAssertEqual(defaults.string(forKey: "translationModel"), "sonnet")
        TranslationModel.migratePreferences(in: defaults)
        XCTAssertEqual(defaults.string(forKey: "translationModel"), "sonnet")
        defaults.set(AuthMethod.codex.rawValue, forKey: "authMethod")
        TranslationModel.migratePreferences(in: defaults)
        XCTAssertEqual(defaults.string(forKey: "translationModel"), "codex-default")
        XCTAssertEqual(TranslationModel.resolve("unknown-retired-model", for: .codex), .codexDefault)
    }

    private func runWithRecordingCLI(_ auth: AuthMethod, model: String) throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("record-cli"), log = directory.appendingPathComponent("args")
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(quote(log.path))
        cat >/dev/null
        output=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '-o' ]; then shift; output="$1"; fi
          shift
        done
        if [ -n "$output" ]; then
          printf '%s' \(quote(translated)) > "$output"
        else
          printf '%s' \(quote(translated))
        fi
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let engine = TranslationEngine(authMethod: auth, translationModel: model, cli: cli.path)
        let result = engine.translateSrt(srtContent: source, sourceLang: "en", targetLangs: [.ko], onProgress: { _ in })
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.translations[.ko], try SrtDocument(translated).render())
        return try String(contentsOf: log, encoding: .utf8).components(separatedBy: "\n")
    }

    func testClaudeExecutionUpgradesSavedVersionToAlias() throws {
        let args = try runWithRecordingCLI(.claudeCode, model: "claude-opus-4-6[1m]")
        let index = try XCTUnwrap(args.firstIndex(of: "--model"))
        XCTAssertEqual(args[index + 1], "opus")
        XCTAssertFalse(args.contains("claude-opus-4-6[1m]"))
        XCTAssertTrue(args.contains("--tools"))
    }

    func testCodexAutomaticBypassesPinnedConfigAndSendsNoModelID() throws {
        let args = try runWithRecordingCLI(.codex, model: "codex-default")
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertFalse(args.contains("--model"))
        XCTAssertTrue(args.contains("--ephemeral"))
    }

    func testCodexExplicitSelectionReachesCLI() throws {
        let args = try runWithRecordingCLI(.codex, model: TranslationModel.codexLuna.rawValue)
        let index = try XCTUnwrap(args.firstIndex(of: "--model"))
        XCTAssertEqual(args[index + 1], "gpt-6-luna")
    }

    func testCodexConfiguredModePreservesUserConfiguration() throws {
        let args = try runWithRecordingCLI(.codex, model: TranslationModel.codexConfigured.rawValue)
        XCTAssertFalse(args.contains("--ignore-user-config"))
        XCTAssertFalse(args.contains("--model"))
        XCTAssertFalse(args.contains("-c"))
    }

    func testLiveCurrentModelsPreserveSubtitleTiming() throws {
        guard ProcessInfo.processInfo.environment["SUBTITLEGEN_LIVE_TRANSLATION_TEST"] == "1" else {
            throw XCTSkip("Requires an authenticated subscription CLI and explicit live-test opt-in")
        }
        for (auth, model) in [(AuthMethod.claudeCode, TranslationModel.claudeOpus),
                              (.claudeCode, .claudeSonnet), (.codex, .codexDefault), (.codex, .codexLuna)] {
            let engine = TranslationEngine(authMethod: auth, translationModel: model.rawValue)
            let result = engine.translateSrt(srtContent: source, sourceLang: "en", targetLangs: [.ko], onProgress: { print("\(model.rawValue): \($0)") })
            XCTAssertTrue(result.failures.isEmpty, "\(model.rawValue): \(result.failures)")
            let output = try XCTUnwrap(result.translations[.ko])
            XCTAssertTrue(try SrtDocument(output).matchesTiming(of: SrtDocument(source)))
            XCTAssertTrue(output.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) })
            print("Verified live translation: \(model.rawValue)\n\(output)")
        }
    }
}
