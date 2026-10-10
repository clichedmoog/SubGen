# Subtitle Maker & Translator 출시 작업

Mirror의 앱 공용 스킬 세 개를 `.agents/skills/`에 가져왔습니다. 스킬은 현재
프로젝트의 자료에서 앱 정보를 읽습니다. 이 저장소의 기본 언어는 영어(미국),
대상은 macOS이며 iOS·광고판·비광고판 구분은 없습니다.

| 작업 | 스킬 | 다음 요청 예 |
| --- | --- | --- |
| 설명·키워드·스크린샷 | [apple-app-listing](../.agents/skills/apple-app-listing/SKILL.md) | `영문 리스팅 초안을 App Store Connect에 저장하고 확인해줘` |
| Release 빌드·검증 | [apple-app-build-prod](../.agents/skills/apple-app-build-prod/SKILL.md) | `직접 배포용 Release DMG를 만들어줘` |
| 스토어 업로드·TestFlight·심사 | [apple-app-submit](../.agents/skills/apple-app-submit/SKILL.md) | `스토어용 빌드 준비 상태를 확인하고 TestFlight에 올려줘` |
| 심사 제출 | 같은 submit 스킬 | `스토어용 앱을 심사에 제출해줘. 수동 출시로 설정해줘` |
| 공개 출시 | 같은 submit 스킬 | `승인된 스토어 버전을 공개 출시해줘` |

앱 식별자·영문 문구·심사 자료·배포 상태의 원본은 [store.config.json](store.config.json),
현재 확인 결과는 [최신 출시 기록](releases/2026-10-10.md)입니다. 자료 준비, 콘솔 저장,
업로드, 처리 완료, 테스트, 심사 제출, 승인, 공개 출시를 각각 기록합니다.

## 한 번에 준비하기

```sh
# 로컬 영문 문구와 앱 정보 검사
python3 Store/scripts/store.py check
# 현재 단계별 남은 일
python3 Store/scripts/store.py status
# 기존 공증 앱·DMG의 서명, 티켓, Gatekeeper, 체크섬 검증
python3 Store/scripts/store.py check --stage direct
# 새 폴더에 문구·필드 지문·설정 스냅샷·직접 배포 명령·남은 일 추출
python3 Store/scripts/store.py prepare --output /tmp/subtitlegen-release-preparation
```

`prepare`는 빌드·업로드·공개를 실행하지 않습니다. 출력 폴더가 이미 있으면
이전 자료를 보존하기 위해 중단합니다. `listing/en-US/`의 원문을
ego-browser의 Node `fs/promises`로 읽어 폼에 입력합니다. 저장 후 재로드하여
영속 값과 원문/지문이 일치하는지 확인합니다. 필드 하나만 확인할 수도 있습니다.

```sh
python3 Store/scripts/store.py copy --field description
python3 .agents/skills/apple-app-listing/scripts/field-sig.py \
  Store/store.config.json listings.en-US.description
```

현재 영문 설명·키워드·지원 URL과 스크린샷 3장은 콘솔에 저장하고 재로드 검증했습니다. 무료 MIT 오픈소스 앱,
한국어 UI, 로그인 없이 가능한 로컬 전사, 적격 ChatGPT 플랜과 사용량 제한을 설명합니다.
실제 OAuth·번역·심사자 접근과 설치된 배포판 확인은 남아 있습니다. 첫 출시에는 `whatsNew`를 추가하지 않습니다.

## 배포 채널과 버전

| 채널 | 현재 버전 | 산출물 | 상태 |
| --- | --- | --- | --- |
| 직접 배포 | `2026.10.09` | Developer ID 앱·공증 DMG | 로컬 검증 완료, 앱 DMG는 아직 공개하지 않음 |
| Mac App Store | `1.0 (4)` | Apple Distribution Archive 및 Mac Installer Distribution 패키지 검증 완료 | Xcode 계정 재인증 후 업로드 예정. 배포된 빌드 3은 내부 TestFlight 테스트 중, 정식 심사 미제출 |

스토어 빌드 `1`, `2`, `3`은 업로드되어 번호를 다시 사용할 수 없습니다. 최신 앱은
`SubGen.app` / `SubGen`이며 App Store 이름·번들 ID·Swift 모듈은 유지합니다.
정식 버전에는 처리된 빌드 `3`을 선택했습니다. 빌드 `1`은 내부 전용입니다.
기존 업로드·공증 산출물은 보존하며 다음 업로드 전 ASC에서 새 번호를 확인합니다.

```sh
# 직접 배포용 기존 파이프라인 명령을 출력하기만 함
python3 Store/scripts/store.py plan --channel direct --output /tmp/subtitlegen-direct
# 스토어용 구현과 설정이 마련되어야 통과
python3 Store/scripts/store.py check --stage store-build
python3 Store/scripts/store.py check --stage review
```

서명된 앱/아카이브의 채널과 식별자는 `inspect`로 검사합니다. 실제 배포 단계에서는
export된 앱과 Mac 패키지 서명·프로파일·모든 중첩 코드도 스킬의 절차대로 확인합니다.
자동 서명 Archive는 개발 서명을 포함할 수 있으므로 스토어 export 뒤의 배포 서명
검증과 구분합니다.

```sh
python3 Store/scripts/store.py inspect build/SubtitleGen.app --channel direct
# 현재 직접 배포 앱을 app-store로 검사하면 준비되지 않은 이유를 표시하고 실패
python3 Store/scripts/store.py inspect build/SubtitleGen.app --channel app-store
```

직접 배포는 `scripts/build-dmg.sh`, `scripts/verify-release.py`를 재사용합니다.
공개 GitHub 릴리스 게시나 파일 업로드는 별도 요청 단계입니다. Whisper 설치 ZIP은
이미 공개되어 있으며 앱 DMG의 공개 여부와 따로 관리합니다.

## Mac App Store로 가기 위한 작업

직접 배포 앱은 첫 실행 후 FFmpeg/Whisper 실행 코드를 내려받으며 외부 Claude Code/
Codex CLI를 사용합니다. 새 스토어 타깃은 App Sandbox를 켜고 ARM64 도구를 앱에
포함합니다. 스토어에서 실행 코드 다운로드와 외부 CLI 번역은 비활성화했습니다. Apple의
[심사 지침 2.4.5·2.5.2](https://developer.apple.com/app-store/review/guidelines/)과 대조했을 때,
현재 공증 DMG를 그대로 스토어에 제출하는 경로는 준비되지 않았습니다. 공증은 이
스토어 조건의 검증을 대신하지 않습니다.

1. **구현·빌드 확인:** `project.yml` → XcodeGen → `SubtitleGen.xcodeproj`,
   `SubtitleGenStore` 스킴, `MAC_APP_STORE` 조건. Release `1.0 (4)`·ARM64·팀·ID 확인.
   `Package.swift`는 직접 배포용으로 유지합니다. 새 네이티브 프로젝트는 XcodeGen으로 재생성합니다.
2. **번들 도구와 개발 실행 확인:** 스토어 FFmpeg/FFprobe 9는 고정 SHA256의 공식
   소스에서 ARM64/macOS 14용으로 빌드합니다. GPL/nonfree 및 외부 코덱 라이브러리를
   비활성화한 LGPL 빌드이며, 전체 대응 소스·라이선스·빌드 레시피를 앱의
   `Contents/Resources/FFmpegSource`에 포함합니다. Whisper 1.8.4는 입력 SHA256으로
   검증하여 `Contents/MacOS`에 넣습니다. 보조 도구는 앱과 같은 팀으로
   서명하고 sandbox + inherit 권한만 갖습니다. 정적 빌드의 의존성은 시스템 경로입니다.
   서명된 Debug 앱에서 HTTPS 데이터 다운로드, FFprobe, FFmpeg, Whisper·Metal·SRT 생성을
   검증했습니다. 새 FFmpeg 도구의 시험 결과와 패키지 검증은 최신 출시 기록에서 확인합니다.
3. **외부 파일 개발 서명 Release 검증 완료:** 파일/폴더 선택 권한과 security-scoped bookmark를 추가했습니다.
   SRT와 임시 영상이 입력 옆에 생성되므로 파일 한 개의 접근 권한만으로 충분하다고 가정하지 않습니다.
   입력 폴더를 허용한 뒤 처리하며 모델·로그는 앱 컨테이너에 저장합니다. 실제 앱에서 외부 폴더 허용·재실행 후 권한 재사용·SRT 저장·영상 교체를 확인했습니다.
   설치된 TestFlight 배포판에서 같은 동작을 확인하는 절차는 남아 있습니다.
4. **구현, 실제 서비스 검증 대기:** 사용자가 무료 오픈소스 앱을 선택했고 앱 소스에
   MIT 라이선스를 적용했습니다. ChatGPT PKCE OAuth·JWT 서명 검증·Keychain 저장·등록별
   refresh 회전·동적 모델 목록·Responses SSE 번역·사용량 제한 처리를 연결했습니다.
   [Sign in with ChatGPT 구현·검증](chatgpt-sign-in.md)에 공식 계약과 증거를 기록합니다.
   외부 CLI에 의존하지 않으며 로그인 없이 전사 가능합니다. 실제 로그인·계정 모델 목록·
   SRT 번역·갱신·연결 취소와 심사자의 접근 방법은 남아 있습니다.
5. **최종 검증 대기:** 개인정보 매니페스트를 추가했습니다. 실제 데이터 처리·의존성,
   Apple Distribution export 패키지 서명 및 Release Mac 실행은 최종 제품으로 검증합니다.
   `readiness`는 근거가 있을 때만 갱신하고 스토어 빌드·리뷰 검사로 이어갑니다.

### 네이티브 빌드와 샌드박스 시험

빌드 머신에는 Xcode 27+ (현재 `.icon` 자산 컴파일)와 XcodeGen이 필요합니다.
아래 명령은 코드·모델을 최종 사용자 기기에서 컴파일/설치하지 않습니다.

```sh
python3 scripts/prepare-store-tools.py
xcodegen generate
xcodebuild -list -project SubtitleGen.xcodeproj
xcodebuild -project SubtitleGen.xcodeproj -scheme SubtitleGenStore \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/store-development -allowProvisioningUpdates build
```

처음 도구를 준비할 때 `scripts/build-store-ffmpeg.sh`가 공식 소스에서 FFmpeg를
빌드합니다. 이후 소스·레시피·바이너리 체크섬이 일치하면 재사용합니다. 직접 배포판의
FFmpeg 자동 다운로드와 기존 공증 DMG는 이 스토어 전용 변경의 영향을 받지 않습니다.

## 내부 TestFlight

사용자가 요청한 내부 베타 배포는 최종 스토어 심사 준비와 구분합니다. 실제 ChatGPT
인증·번역, 외부 폴더 재실행 권한과 배포판 애니메이션은 베타에서 확인할 항목으로
명시하며 해당 readiness를 컴파일/패키지 성공으로 켜지 않습니다. 테스트 안내는
[testflight-what-to-test.en-US.txt](testflight-what-to-test.en-US.txt)에 있습니다.

최신 후보는 정식 심사에서도 선택할 수 있도록 `testFlightInternalTestingOnly=false`로
로컬 App Store export를 생성합니다. 업로드 전에
아래 명령으로 패키지 서명·프로파일·앱/도구 신원·소스·아이콘을 검사합니다.
이 검사는 최종 서비스/개인정보 검증이나 실제 설치를 완료로 표시하지 않습니다.

```sh
python3 Store/scripts/verify-testflight-package.py /path/to/SubGen.pkg
```

현재 콘솔 빌드/계정 확인과 업로드 결과는 최신 출시 기록에 남깁니다. 내부 베타는
스토어 리스팅 저장·정식 심사 제출·가격 변경·공개 링크 생성과 별개입니다.

이 `build` 결과는 개발 서명 앱이며 스토어 패키지가 아닙니다. 샌드박스 시험은
SwiftPM 시험과 분리해 앱을 호스트로 실행합니다. 아래 QA 식별자는 기존 앱 설정과
분리하기 위한 로컬 시험용이며 App Store Connect 식별자를 변경하지 않습니다.
이미 보유한 같은 팀의 Apple Development 인증서를 사용합니다.

```sh
xcodebuild -project SubtitleGen.xcodeproj -scheme SubtitleGenStore \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/store-runtime-tests \
  PRODUCT_BUNDLE_IDENTIFIER=com.clichedmoog.subtitle-generator.store-qa \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Development' test
```

이 시험은 공개 시험 음성과 Tiny 모델을 데이터로 다운로드하므로 네트워크가 필요합니다.
도구 탐색은 번들만 사용하고 실제 SRT·자동 언어 감지·Metal을 확인합니다. 컨테이너 내
저장/북마크 시험이 외부 폴더의 재실행 권한 검증을 대신하지 않습니다.

준비가 완료되면 `plan --channel app-store --output <저장소 밖 경로>`로 Archive/로컬
export 명령을 출력합니다. 스토어 export는 `method=app-store-connect`,
`destination=export`, 빌드 번호 자동 변경 없음으로 만들며 업로드하지 않습니다.
설치된 Xcode의 옵션·destination을 먼저 확인합니다. Developer ID DMG와 공증용 임시
아카이브는 스토어 업로드에 사용하지 않습니다.

## 개인정보·심사·공개 주소

[privacy-disclosure.json](privacy-disclosure.json)은 코드 근거와 미확인 사항이며
App Privacy의 저장/공개 완료를 뜻하지 않습니다. 로컬 전사와 번역 서비스로 전송되는
자막을 구분합니다. 외부 CLI의 공급자 설정 및 데이터 보관도 확인해야 합니다.

지원·개인정보 URL, 저작권 표시, 심사 연락처는 아직 미확정입니다. 다른 앱의 주소나
연락처를 가져오지 않았습니다. [web/](web/)에는 게시 전 지원·정책 초안이 있습니다.
실제 공개 주소와 최종 스토어 구현을 확인한 후 설정에 반영합니다. 공개 서버에
게시되었다고 표시하거나 가짜 URL로 검사 결과를 통과시키지 않습니다.

현재 콘솔은 기본값인 **승인 후 자동 출시**와 **로그인 필요**가 선택되어 있습니다.
이번 작업은 이를 변경하지 않았습니다. 앱 자체 계정은 없지만 번역 서비스 인증이
필요하므로 `demoAccountRequired`는 최종 스토어 구현과 심사자 접근을 확인한 뒤 결정합니다.
수동 출시를 원하면 다음 심사 요청에 명시하고 실제 콘솔 저장값을 확인합니다.

## Mac 스크린샷

실제 Mac 앱 창을 `01-transcribe.png`, `02-translate.png`, `03-setup.png`로 캡처합니다.
개인 파일명·자막·계정이 보이지 않는 자체 시험 자료를 사용합니다. 원본은 저장소 밖에
보관하며 현재 UI가 한국어라는 점을 유지합니다. iPhone 캡처나 프레임은 사용하지 않습니다.

```sh
python3 -m pip install Pillow
python3 Store/scripts/build-screenshots.py /tmp/subtitlegen-captures \
  --output /tmp/subtitlegen-store-shots --size 2560x1600
```

합성은 원본 앱 창을 같은 비율로 배치하고 P3 프로필을 sRGB로 변환합니다. 문구는
[screenshots/headlines.json](screenshots/headlines.json), 출력은 번호순 RGB JPEG와
검토용 contact sheet, 원본/출력 해시를 담은 manifest입니다. 자동 합성 성공과 눈으로
검토한 상태는 별도로 기록합니다. 아직 실제 제출용 캡처·업로드는 하지 않았습니다.

2026-10-09 확인한 [Apple Mac 규격](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/):
16:10 비율의 `1280×800`, `1440×900`, `2560×1600`, `2880×1800`입니다.
업로드 시 해당 macOS 플랫폼의 현재 규격과 순서·개수·언어를 다시 확인합니다.
