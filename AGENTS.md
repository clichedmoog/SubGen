# SubtitleGen release work

Read `README.md`, `CLAUDE.md`, `Store/README.md`, `Store/store.config.json` and
`Store/releases/2026-10-10.md` before listing, build or submission work.
Use the repository-owned skills:

- `.agents/skills/apple-app-build-prod/SKILL.md`
- `.agents/skills/apple-app-listing/SKILL.md`
- `.agents/skills/apple-app-submit/SKILL.md`

This is Subtitle Maker & Translator, a native macOS 14+ ARM64 app. Resolve its
bundle ID, team, store ID, channel and version from its own configuration and
current App Store Connect record. Do not modify sibling Mirror or Flashlight.
Do not copy another app's contacts, testers, ad configuration or privacy answers.

SwiftPM (`Package.swift`) builds the direct-distribution app. Both variants use
`SubGen.app` with executable `SubGen`; source/module names remain `SubtitleGen`.
Uploaded TestFlight 1.0 (1) used `SubtitleGen.app`; latest 1.0 (3) uses `SubGen.app`
and is Testing in the internal group. Builds 1, 2 and 3 cannot be reused. The native store
target is generated from `project.yml` with XcodeGen; use `SubtitleGen.xcodeproj`
and the `SubtitleGenStore` scheme. Run `scripts/prepare-store-tools.py` before
building to stage pinned ARM64 helpers. Store model downloads use URLSession;
executable downloads and external CLI translation are disabled in that variant.
The notarized Developer ID app/DMG cannot be uploaded as a Mac App Store build.
Actual external-folder QA and final privacy/export verification passed. Live
ChatGPT translation and installed TestFlight runtime verification remain gated. Do not mark them complete from compiler success.
The user chose a free open-source app; its own source is MIT licensed. Read
`Store/chatgpt-sign-in.md` for the implemented SIWC backend and pending live
verification. Do not mark translation verified from fixtures/compiler success.
Third-party tool licenses and corresponding-source obligations remain separate.

Primary listing language is English (U.S.); the current app interface is Korean.
English listing copy and three actual Mac screenshots were saved and reloaded in
the console on 2026-10-10. Review remains pending live/distributed verification.
Use ego-browser for all browser work; confirm account, app and macOS platform.
The console currently has automatic release after approval. Preserve the actual
mode unless instructed to change it; a future request specifying manual release
authorizes that change. Keep review, approval and public release separate.

Preparation does not authorize store writes, upload, tester invitations, review,
public release or pricing changes. When the user requests a stage, complete the
authorized stage without redundant confirmation. Record exact verification and
unresolved inputs in the release report. Keep keys, certificates, profiles,
raw captures, archives, packages and build logs out of tracked source.
