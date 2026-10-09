# CLAUDE.md

## Build and tests

```sh
swift build
swift build -c release
swift test
SUBTITLEGEN_WHISPER_TEST=1 swift test
swift build --show-bin-path
```

Tests require Xcode. Use the bin path reported by SwiftPM; build output layouts differ across SwiftPM build modes.

## Architecture

macOS 14+ SwiftUI app, SwiftPM executable `SubGen` and module `SubtitleGen`. App bundles use `SubGen.app`; the App Store name remains Subtitle Maker & Translator. CLI-based whisper.cpp transcription with GGML models and Metal. Translation uses authenticated Claude Code or Codex CLI.

- `ToolResolver`: native Mach-O/Universal validation, bounded executable probes, shared by UI checks and transcription. App Support, bundle, then native Homebrew/local paths. Detect hardware ARM64 even under Rosetta.
- `FFmpegDistribution`: pinned architecture-specific static binaries and SHA256. Keep URLs/hashes aligned with `scripts/bundle-ffmpeg.sh`.
- `ToolArchiveInstaller`: prebuilt ZIP installation with native architecture, SHA256, Developer ID team and execution checks. Preserve existing tools on failure/cancellation/concurrent changes. `WhisperDistribution` reads `Resources/ToolDownloads.plist`; publish the corresponding ZIP before distributing a fresh-user app.
- `ProcessRunner`: concurrently drain stdout/stderr; large stdin is asynchronous; return launch/nonzero/timeout/cancel failures. `CancellationToken` owns all processes per file. Do not use waitUntilExit before draining pipes.
- `AudioPreparation`: actual sample/chunk WAV extraction. Never combine whisper language detection or VAD with offsets into a full audio file. Restore the chunk start time in parsed cues.
- `SrtDocument`: parse every cue and validate exact source/translation numbers, counts and timings. Normal dialogue is allowed to contain words such as sorry/cannot.
- `TranscriptionEngine`: dynamic queue, file UUID callbacks, per-file cancellation, up to two background translation files. Existing sidecars need exact filename matches. Text subtitle tracks are extracted before translation.
- `TranslationEngine`: up to two languages per file, 200 cues per chunk, three attempts, 600-second request timeout. Prompt through stdin in an isolated temporary directory. Translation failures must propagate to file status.
- `SafeFileReplacement`: validated candidate alongside the destination, check original snapshot, then atomic rename. Never delete the original before moving a candidate. Delete generated SRTs only after all requested work succeeds and embedding has been verified; never delete pre-existing user SRTs.
- `ContentView`: options in AppStorage, queue in UserDefaults, callbacks resolve UUIDs. Protect active entries during removal/reset. Surface installation and preflight errors.

## Logs and distribution

All builds log to `~/Library/Logs/SubtitleGen.log`, with a 5MB rotation threshold.

`bash scripts/build-dmg.sh` builds a lightweight app with first-run tool/model setup, signs, creates a DMG and notarizes the app and DMG separately. Tools are not bundled in distribution builds. `build-whisper-download.sh` builds a signed static macOS 14+ Whisper ZIP, updates the pinned download configuration, and notarizes it before publication. `NOTARIZE=0` explicitly builds signed-only artifacts with pending notarization status. `--package-only` reuses a verified signed app for notarization/packaging. It uses a configured Developer ID and keychain profile. Do not publish or notarize without user authorization. Local verification can use a separate ad-hoc-signed app bundle.

FFmpeg ISO metadata uses three-character codes (`jpn`, `kor`) while Whisper/SRT filenames use two-character codes (`ja`, `ko`). MP4/MOV use mov_text, MKV subrip, WebM webvtt; audio input keeps its sidecar.

Preserve existing user changes. Use commit messages `type(scope): subject` when a commit is requested.

## Listing and release coordination

Start at AGENTS.md and Store/README.md; read Store/store.config.json and
Store/releases/2026-10-10.md. Use the three project-owned apple-app skills.
SwiftPM/Developer ID notarized DMGs are direct distribution; Mac App Store
requires a separate verified native app target, sandbox, self-contained tools
and compatible translation backend. The native target now exists: generate
SubtitleGen.xcodeproj from project.yml with XcodeGen; use SubtitleGenStore.
Stage pinned tools using scripts/prepare-store-tools.py before native builds.
Store external CLI execution is disabled. Read Store/chatgpt-sign-in.md for
the implemented OAuth backend and pending live verification. The user chose
a free open-source app; its own source is MIT licensed. Translation must be
verified against the live service before updating the readiness gate.
Canonical English copy is a draft and
the current UI is Korean. Do not reuse Mirror/Flashlight identity or contacts.
Use ego-browser and preserve the observed release mode unless instructed.
Record actual console persistence, delivery, processing, review and public
release separately. Preparation is not authorization for those external steps.
