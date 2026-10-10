# Subtitle Maker & Translator

GitHub 저장소: [clichedmoog/SubGen](https://github.com/clichedmoog/SubGen).

앱 파일과 실행파일의 짧은 이름은 SubGen이며 소스 프로젝트·모듈은 SubtitleGen입니다. [App Store Connect 앱](https://appstoreconnect.apple.com/apps/6820884731/distribution/info): macOS, 기본 언어 영어(미국), bundle ID `com.clichedmoog.subtitle-generator`, 개인 팀 `N9LYHMUDKA`. 현재 앱 레코드는 제출 준비 중이며 스토어 심사에 제출하지 않았습니다.

무료 오픈소스 macOS 앱입니다. 앱 소스는 [MIT 라이선스](LICENSE)를 적용하고, FFmpeg·Whisper 등은 기존 라이선스를 유지합니다. 직접 배포판은 Claude Code/Codex CLI, 스토어판은 ChatGPT 로그인으로 자막을 번역합니다.

## 스토어 리스팅·심사·출시 준비

Mirror의 공용 `apple-app-build-prod`, `apple-app-listing`, `apple-app-submit` 스킬을
이 저장소의 `.agents/skills/`에 연결했습니다. [AGENTS.md](AGENTS.md)와
[Store/README.md](Store/README.md)가 작업 진입점이며, 영문 문구·앱 식별자·준비 상태는
[Store/store.config.json](Store/store.config.json), 실제 확인 결과는
[최신 출시 기록](Store/releases/2026-10-10.md)에 있습니다.

```sh
python3 Store/scripts/store.py check
python3 Store/scripts/store.py status
python3 Store/scripts/store.py check --stage direct
python3 Store/scripts/store.py prepare --output /tmp/subtitlegen-release-preparation
```

공증된 DMG는 직접 배포용입니다. 스토어판은 ARM64 도구를 번들하고 샌드박스를 사용합니다.
현재 배포된 `1.0 (3)`은 `SubGen.app` 이름으로 내부 TestFlight에서 테스트 중입니다.
로그인 대기 개선에 이어 모델 자동 다운로드, 전사 중간 시간/추정 진행률, Whisper의
빈·0초 SRT 구간 처리를 수정했습니다. 회귀 171개 중 166개 통과·5개 제외·실패 0,
서명된 Release 샌드박스 5개 통과를 확인했고 수정 배포 패키지의 서명·프로파일·번들 도구 검증도 마쳤습니다.
새 TestFlight 업로드 전 Xcode 계정 재인증과 현재 빌드 번호 확인이 필요합니다.
실제 앱의 모델 다운로드·전사·외부 폴더 권한 재사용·영상 자막 내장을 확인했습니다.
개인정보처리방침과 App Privacy도 게시했고 영문 리스팅·스크린샷 3장을 저장했습니다.
실제 ChatGPT 로그인·번역과 설치된 TestFlight 배포판 확인이 남아 있어 정식 심사는
아직 제출하지 않았습니다. [ChatGPT 연동과 검증](Store/chatgpt-sign-in.md)을 참고하세요.
기본 스토어 정보는 영문이고 현재 앱 UI는 한국어입니다. 승인 후 자동 출시 설정을 유지합니다.
기존 공증 DMG와 TestFlight 빌드 `1` 산출물은 `SubtitleGen` 이름으로 보존합니다.

## 요구 사항

- macOS 14 이상, Apple Silicon Mac
- 전사: whisper.cpp (`whisper-cli`)와 GGML 모델. Metal GPU를 사용합니다.
- 오디오 처리·자막 내장: FFmpeg와 FFprobe
- 직접 배포판 번역: 로그인된 Claude Code 또는 Codex CLI.
- 스토어판 번역: 플랜 사용을 허용한 적격 ChatGPT 계정. 별도 CLI/API 키 없이 사용하며, 계정별 사용량 제한이 적용됩니다.
- 앱은 무료이며 ChatGPT 구독·크레딧을 제공하지 않습니다. 로그인 없이 로컬 전사를 사용할 수 있습니다.

## 빌드·실행

```sh
swift build
swift test
# 실제 Whisper 시험 음성 검증도 실행 (로컬 모델과 Samantha 음성 필요)
SUBTITLEGEN_WHISPER_TEST=1 swift test
# 실제 공개 Whisper URL로 설치 검증 (ToolDownloads.plist의 SHA256 사용):
SUBTITLEGEN_WHISPER_URL="https://github.com/clichedmoog/SubGen/releases/download/tools-2026.10.09/whisper-cli-1.8.4-macos14-arm64.zip" \
SUBTITLEGEN_WHISPER_SHA256="7361079edd3fc7204c68053ed1567450e20c27c3ea3f98c258c8c7ea7159a1d2" \
swift test --filter ToolInstallationTests.testSignedWhisperArchiveInstallsWithoutBuildTools
```

로컬 앱 번들을 만들 때 실행 파일은 `swift build --show-bin-path`가 반환하는 경로에서 복사합니다. 빌드 모드별 출력 경로에 대응하기 위해 이 경로를 사용합니다.

```sh
swift build
APP=build/SubGen-dev.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build --show-bin-path)/SubGen" "$APP/Contents/MacOS/"
cp SubtitleGen/Resources/Info.plist "$APP/Contents/"
cp SubtitleGen/Resources/AppIcon.icns "$APP/Contents/Resources/"
bash scripts/compile-app-icon.sh "$APP"
cp SubtitleGen/Resources/ToolDownloads.plist "$APP/Contents/Resources/"
bash scripts/bundle-ffmpeg.sh "$APP/Contents/MacOS"
# 필요하면 whisper-cli와 해당 dylib도 기존 앱 번들에서 복사합니다.
codesign --force --deep --sign - "$APP"
open "$APP"
```

## 직접 배포판의 첫 실행과 설치

배포용 앱에는 FFmpeg·FFprobe·Whisper·모델을 포함하지 않습니다. 첫 실행의 **자막 작업 준비** 화면에서 필요한 항목과 모델 용량을 안내하고 **필요한 항목 설치** 버튼으로 설치합니다. 기존에 사용 가능한 도구·모델은 재사용합니다. 나중에 설치하려면 **설치 안내** 버튼으로 다시 열 수 있습니다.

- FFmpeg/FFprobe: CPU에 맞는 정적 배포 파일 다운로드 → SHA256·실행 검증 → 설치.
- Whisper: 사전 빌드한 macOS 14+ ARM64 ZIP 다운로드 → SHA256·개발자 서명·실행 검증 → 설치. 사용자 Mac에 Homebrew·CMake·Xcode가 필요하지 않습니다.
- 모델: 선택한 모델을 별도로 다운로드합니다. Large v3 Turbo는 약 1.6GB입니다.
- 설치 중단·실패 시 기존 도구와 모델을 보존합니다. 번역은 별도로 설치하고 로그인한 Claude Code/Codex CLI를 사용합니다.

**2026-10-09 준비 상태:** Whisper ZIP을 [GitHub 사전 릴리스](https://github.com/clichedmoog/SubGen/releases/tag/tools-2026.10.09)에 공개했습니다. 로그인 없는 다운로드와 실제 설치 코드의 SHA256·개발자 서명·ARM64 실행 검증을 통과했으며, `ToolDownloads.plist`의 자동 설치 주소가 활성화됐습니다. Xcode에 로그인된 개인 팀 계정으로 앱·DMG·Whisper의 Apple 공증을 완료했습니다. 앱과 DMG는 티켓 부착 및 Gatekeeper의 `Notarized Developer ID` 검증을 통과했습니다. Whisper 단독 실행 파일의 온라인 공증 티켓도 확인했으며, 공개 ZIP과 다운로드 체크섬은 그대로 유지됩니다.

## 배포 패키지

```sh
# 새 Whisper 릴리스: 검증된 소스에서 macOS 14용으로 빌드·서명·공증하고
# 다운로드 설정(바이너리 SHA256)을 갱신합니다.
bash scripts/build-whisper-download.sh
# 생성된 dist/whisper-cli-*.zip을 설정된 HTTPS 릴리스 주소에 게시한 뒤:
bash scripts/build-dmg.sh

# 공증 자격 증명 없이 로컬 서명 패키지만 준비할 때:
NOTARIZE=0 bash scripts/build-dmg.sh
# 기존 앱을 공증하고 DMG를 다시 만들 때 (같은 VERSION 지정):
VERSION=2026.10.09 bash scripts/build-dmg.sh --package-only
```

`build-dmg.sh`는 기본적으로 `notarytool` 키체인 프로필을 확인하고, 프로필을 사용할 수 없으면 Xcode에 등록된 개발자 계정으로 공증합니다. Xcode 경로에는 별도의 앱 전용 암호 등록이 필요하지 않습니다. `NOTARIZATION_BACKEND=xcode` 또는 `notarytool`로 경로를 지정할 수 있습니다.

`notarytool` 경로를 사용할 때는 공증 자격 증명을 로컬 터미널에서 한 번 등록합니다. 비밀번호 옵션을 생략하면 안전한 입력 프롬프트가 표시됩니다.

```sh
xcrun notarytool store-credentials notarytool-profile --team-id N9LYHMUDKA
```

Apple ID와 해당 계정의 **앱 전용 암호**를 입력합니다. 이 키체인 프로필은 Developer ID 인증서 및 Xcode 로그인과 별개입니다.

`scripts/notarize-xcode-archive.py`는 기존 서명 앱을 Xcode 아카이브로 제출하고 승인된 앱을 내보냅니다. `--payload`로 추가한 DMG/ZIP도 Apple의 [중첩 컨테이너 공증](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)을 받습니다. 추가 파일을 넣은 임시 제출 앱은 배포하지 않습니다. DMG/PKG에는 티켓을 부착하며, ZIP에 든 단독 실행 파일은 `codesign --verify --strict --check-notarization`으로 온라인 티켓을 확인합니다. 로그·아카이브는 `build/notarization/`에 보존하고, 처리 대기 시 같은 인수에 `--resume`을 추가해 재제출 없이 이어갑니다.

`build-dmg.sh`는 매번 새 앱 번들을 만들며 빌드 머신의 Xcode 경로를 제거합니다. 공증하는 경우 앱을 먼저 공증·staple하고, 이를 담은 DMG를 공증·staple합니다. `Accepted` 상태와 Gatekeeper를 검증한 뒤 체크섬과 JSON 배포 정보를 생성합니다. 서명만 한 패키지는 파일명에 `-signed`가 붙으며 공증 완료로 표시하지 않습니다. `DEVELOPER_ID`, `KEYCHAIN_PROFILE`, `VERSION`, `TOOLS_RELEASE_TAG`, `TOOLS_DOWNLOAD_BASE_URL`로 배포 설정을 조정할 수 있습니다.

Whisper 다운로드 설정은 `SubtitleGen/Resources/ToolDownloads.plist`에 있습니다. 도구를 재서명·재빌드하면 SHA256이 달라지므로 ZIP·설정·앱을 함께 갱신합니다. 패키지 검증: `python3 scripts/verify-release.py build/SubGen.app arm64`.

앱 아이콘은 Opus xhigh의 겹친 말풍선 형태에 iPhone 미러링을 참고한 Mirroring Blue 색상을 적용했습니다. SVG 원본·1024px 미리보기·네이티브 `AppIcon.icon`은 `SubtitleGen/Resources/IconSource/`에 있습니다. `bash scripts/generate-app-icon.sh`는 16/32px 전용 원본을 포함한 ICNS를 재생성합니다. Xcode 27 이상의 `bash scripts/compile-app-icon.sh /path/to/SubGen.app`은 Liquid Glass의 밝은·어두운·색조 레이어를 `Assets.car`로 컴파일하고 앱의 아이콘 정보를 연결합니다. 배포 빌드에서 자동 실행하며 ICNS도 함께 보존합니다.

최초 아이콘 후보 4종은 [아이콘 비교](design/icon-comparison/README.md)에 보존합니다. 선택한 Opus xhigh의 색상 3종 비교·원본·검증 기록은 [색상 수정](design/icon-colour-revision/README.md)에 있습니다. 현재 DMG에는 최신 번역 모델 선택과 새 네이티브 아이콘을 반영합니다.

## 도구 선택·설치

도구 검사와 실제 전사가 같은 `ToolResolver`를 사용합니다.

1. `~/Library/Application Support/SubtitleGenerator/bin`
2. 앱 번들 `Contents/MacOS`
3. `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`

현재 하드웨어의 ARM64 또는 Intel 아키텍처를 확인합니다. 맞는 Mach-O 또는 Universal 바이너리만 선택하고, 제한 시간 내 `-version` / `--help`가 성공해야 설치 완료로 판단합니다. 잘못된 아키텍처, 실행 권한 누락, dylib 누락, 실행 실패 시 다음 경로를 확인합니다. 기존 Intel 도구가 있어도 Apple Silicon용 Homebrew 도구를 사용할 수 있습니다.

앱에서 자동 설치할 때 [OSXExperts 정적 빌드](https://www.osxexperts.net/)의 ARM64 9.0 또는 Intel 8.0을 다운로드하고, 고정된 SHA256과 실제 실행을 검증한 뒤 교체합니다. 개발용 번들 스크립트도 같은 기준을 사용합니다. 실제 배포용 앱에는 이 실행 파일들을 넣지 않고 첫 실행 시 설치합니다. 업데이트 시 `FFmpegDistribution`과 `scripts/bundle-ffmpeg.sh`의 URL·체크섬을 함께 갱신합니다.

Homebrew로도 설치할 수 있습니다.

```sh
brew install ffmpeg whisper-cpp
```

GGML 모델은 앱에서 다운로드하며 `~/.cache/whisper-cpp`에 저장합니다. 다운로드는 임시 파일에 먼저 저장하고, 실패·중단 시 기존 모델을 보존합니다.

## 처리 방식

전사 중에는 처리한 오디오 시간/전체 시간과 청크 번호를, 번역 중에는 언어별로
검증한 자막 개수/전체 개수와 요청 중인 묶음을 표시합니다. 파일과 전체 작업에
회전하는 처리 표시를 함께 사용합니다. 전체 진행률은 전사·번역·저장·내장 단계를
합산한 진행도이며 남은 실행 시간을 보장하는 비율은 아닙니다. 번역은 스트리밍 텍스트를
받았다는 것만으로 완료 개수를 늘리지 않고, 묶음의 SRT 검증을 마친 뒤 반영합니다.

번역 언어·전사 언어·출력 방식을 바꾸면 완료한 파일도 새 작업의 대기 상태가 됩니다.
이전 진행률·번역 배지·소요 시간은 초기화하지만 실제 자막 파일은 보존합니다.
알려진 원본 언어는 큐와 함께 저장하여 자동 모드에서 번역 자막을 원본으로 선택하는
문제를 줄입니다. 기존 SRT/내장 자막을 재사용하는 작업도 완료로 표시합니다.


번역 모델은 오래된 날짜별 ID 대신 CLI의 최신 모델 선택 기능을 사용합니다.

- Claude: `opus` (품질 우선, 기본값), `sonnet` (균형), `haiku` (속도 우선). 기존 Opus 4.6/Opus 4/Sonnet 4/Haiku 4.5 설정은 같은 계열의 별칭으로 이전합니다. 별칭은 CLI 버전과 공급자 설정에 따라 해석되므로 Claude Code를 최신으로 유지하세요. 공급자나 `ANTHROPIC_DEFAULT_*_MODEL` 설정이 모델을 고정할 수 있습니다.
- Codex: **자동 (Codex 권장 모델)**은 `--ignore-user-config`로 사용자 설정의 오래된 모델 고정을 건너뛰고, 모델 ID를 지정하지 않아 CLI 권장 모델을 따릅니다. 인증 정보는 유지합니다. 이는 전 세계의 모든 최신 모델을 찾는 기능이 아니라 설치된 CLI와 계정에서 제공하는 권장 모델입니다. 최신 Codex CLI가 필요합니다.
- Codex에서 GPT-6.1 Sol (균형), GPT-6 Luna (속도), GPT-6 Astra (품질)를 직접 선택할 수도 있습니다. 직접 선택한 ID는 해당 버전에 고정되며 계정에 접근 권한이 있어야 합니다. **Codex 사용자 설정 따르기**는 모델·공급자·추론 설정을 유지하므로 사내 게이트웨이/사용자 지정 공급자에 사용합니다. 자동 모드는 사용자 모델·공급자·MCP 설정을 읽지 않습니다.
- Claude와 Codex의 앱 지정 모델은 medium 추론 강도로 번역합니다. Codex 사용자 설정 모드는 기존 추론 설정을 유지합니다. 모델 접근 오류는 실패로 표시하며 다른 모델로 조용히 바꾸지 않습니다.

2026-10-09 공식 문서 기준 Claude 별칭은 Anthropic에서 Opus/Sonnet/Haiku 5.5를 가리킵니다. 로컬 Codex 0.162.0의 자동 선택은 GPT-6.1 Sol로 확인했습니다. 안내: [Claude 모델 별칭](https://code.claude.com/docs/en/model-config), [Codex 모델](https://developers.openai.com/codex/models), [Codex CLI 옵션](https://developers.openai.com/codex/cli/reference).

- 입력: MP4, MOV, MKV, M4V, AVI, WebM, FLV, M4A, WAV, MP3
- 출력: `영상명.en.srt`, `영상명.ko.srt` 등의 SRT
- 언어 감지: 실제 30초 이하 WAV 샘플 최대 8개를 추출합니다. 신뢰도 0.5 이상인 지원 언어를 사용하며, 불확실하면 언어 지정을 안내합니다.
- 전사: 실제 30분 WAV 청크를 추출해 VAD와 Whisper로 처리합니다. 청크의 상대 시간을 원래 영상 시간으로 복원합니다. 청크 실패나 SRT 누락은 전체 파일 실패로 전달합니다.
- 기존 자막: 정확히 일치하는 파일명의 SRT를 재사용하거나, 텍스트 형식의 내장 자막을 SRT로 추출합니다. 이미지 형식 자막은 직접 추출·번역하지 않고 음성을 전사합니다.
- 번역: 200개 항목씩 처리하며 원문의 번호·개수·타임스탬프를 모두 검증합니다. 파일당 최대 2개 언어, 최대 2개 파일을 병렬 번역합니다. 번역 실패는 완료로 표시하지 않습니다.
- 외부 프로세스: stdout/stderr를 동시에 읽습니다. 실행 시간 제한과 파일별 취소를 적용하며, 번역에는 600초/청크 제한이 있습니다. 실패 이유를 파일 목록에 표시합니다.

## 파일 보존

MP4/MOV/M4V는 `mov_text`, MKV는 SRT, WebM은 WebVTT 자막을 내장합니다. 음성 입력은 SRT 파일을 유지합니다. 지원하지 않는 영상 형식이나 내장 실패 시 생성된 SRT를 보존하고 실패를 표시합니다.

내장 결과의 길이·영상/음성 트랙 수·자막 언어를 검증한 뒤 같은 디렉터리의 임시 영상을 원본에 원자적으로 교체합니다. 처리 중 원본이 변경되면 교체를 거부합니다. 실패한 내장 작업은 원본을 교체하지 않으며, 이미 성공한 내장 결과와 생성된 SRT는 유지합니다. 성공 시에도 사용자가 기존에 가지고 있던 SRT는 삭제하지 않습니다.

`⌘R`: 시작, `⌘.`: 중단. 처리 중 추가 파일도 큐에 포함되며 상태는 파일 ID로 추적합니다.

로그: `~/Library/Logs/SubtitleGen.log` (5MB 초과 시 이전 로그 1개 보관). 릴리스 빌드에서도 기록합니다.

## 검증

회귀 테스트는 아키텍처 탐색, 출력 버퍼 초과, 큰 stdin, 타임아웃·취소, SRT 누락/시간 변경, 원본 교체 실패, 실제 FFmpeg 자막 내장·추출을 확인합니다. 번역 회귀 테스트는 모의 CLI 응답과 실행 인자 기록용 CLI로 모델 설정 이전·실제 전달을 검증합니다. 기본 테스트는 번역 요청을 보내지 않습니다. 아래 명령은 로그인된 구독 CLI에서 실제 번역을 요청합니다.

```sh
SUBTITLEGEN_LIVE_TRANSLATION_TEST=1 swift test --filter TranslationModelTests
```

## License

MIT
