# Apple 번역 두 번째 번역 방식 — 설계 (2026-10-12)

## 목표

ChatGPT 계정이 없는 사용자와 App Store 심사자도 자막 번역을 쓸 수 있게 한다.
ChatGPT를 첫 번째 번역 방식으로 유지하고, Apple Translation 프레임워크를 두 번째
방식(기기 내 처리, 무료, 계정 불필요)으로 추가한다.

성공 기준: macOS 26 이상 스토어판에서 계정 없이 SRT 번역이 끝나고, 번역 결과의
자막 번호·개수·시간이 원문과 같다. 언어 팩이 없을 때 사용자가 무엇을 해야 하는지 안다.

## 결정 사항 (사용자 확인)

- 스토어판(`MAC_APP_STORE`)에만 추가한다. 직접 배포 DMG의 Claude Code/Codex CLI 번역은 그대로 둔다.
- macOS 26 이상에서만 제공한다. 엔진이 `TranslationSession(installedSource:target:)`로 세션을
  직접 만든다. 그보다 낮은 macOS에서는 선택지를 비활성화하고 이유를 표시한다.
- 언어 팩: 원본 언어가 지정돼 있으면 처리 시작 전에 시스템 다운로드 확인을 띄운다.
  자동 감지로 정해진 언어의 팩이 없으면 번역 직전에 시스템 다운로드 확인을 띄우고(앱이 뒤에 있으면 Dock 알림),
  설치가 끝날 때까지 그 파일의 번역만 기다린 뒤 번역한다(2026-10-12 사용자 요청으로 변경). 거절하면 그 번역만 실패,
  15분 안에 설치되지 않으면 시간 초과로 실패하며 전사 SRT는 보존한다. 같은 언어 쌍 요청은 확인 창 하나를 공유한다.

## 구조

기존 `TranslationEngine`의 `request: (String, TranslationLanguage) -> ProcessResult` 주입
지점을 재사용한다(ChatGPT와 같은 방식). 따라서 200개 묶음 분할, 3회 재시도, 번호·개수·
시간 일치 검증(`SrtDocument.matchesTiming`), 진행률, 실패 전파는 바뀌지 않는다.

### 구성 요소

1. `TranslationProvider` (Models.swift): `chatGPT`, `apple`. 라벨 "ChatGPT", "Apple 번역 (기기 내)".
   스토어판 설정 키 `store.translationProvider`, 기본값 `chatGPT`.
2. `AppleTranslationMapping` (새 파일, 프레임워크 비의존 순수 로직, SwiftPM 테스트 대상):
   - `language(for code: String) -> String?`: Whisper/SRT 2자 코드 → BCP-47 식별자.
     `zh` → `zh-Hans`, 그 외 지원 코드는 그대로. 알 수 없는 코드는 nil.
   - `requests(for document: SrtDocument) -> [(id: String, text: String)]`: 자막 번호를 ID로,
     여러 줄 텍스트는 공백 하나로 이어 붙인다.
   - `assemble(_ document: SrtDocument, translations: [String: String]) throws -> SrtDocument`:
     같은 번호·시간으로 다시 조립한다. 누락·빈 번역이 있으면 오류(재시도 가능).
3. `AppleSubtitleTranslator` (새 파일, `import Translation`, `@available(macOS 26, *)`):
   - `status(source:target:) async -> LanguageAvailability.Status`
   - `request(_ srt: String, source: String, target: TranslationLanguage, cancellation:) -> ProcessResult`:
     SRT 파싱 → `TranslationSession(installedSource:target:)` → `translations(from:)`
     (`clientIdentifier` = 자막 번호) → `assemble` → 렌더링한 SRT를 `stdout`으로 반환.
     비동기 호출은 `ChatGPTSubtitleClient.request`와 같은 방식으로 동기 결과로 바꾼다.
     취소 토큰이 취소되면 `session.cancel()`을 호출하고 `.cancelled`를 반환한다.
   - 오류 대응: `notInstalled`, `unsupportedSourceLanguage`, `unsupportedTargetLanguage`,
     `unsupportedLanguagePairing`은 `.service(안내 문구, retryable: false)`. 그 밖의 오류는
     `.service(설명, retryable: true)`.
4. `TranscriptionEngine.Options.translationProvider` 추가. 스토어판 번역 분기에서
   `apple`이면 macOS 26 확인 후 `AppleSubtitleTranslator`를 주입하고, `chatGPT`이면 기존 경로.
   ChatGPT 계정·모델 확인은 `chatGPT` 방식일 때만 한다.

### 화면 (스토어판 작업 설정)

- 번역 영역 맨 위에 `번역 방식` Picker: ChatGPT / Apple 번역 (기기 내).
- `apple` 선택 시 ChatGPT 계정·모델 UI를 숨기고 다음을 표시한다.
  - "계정 없이 이 Mac에서 번역합니다. 자막이 외부로 전송되지 않습니다."
  - macOS 26 미만: 선택지 비활성화와 "macOS 26 이상에서 사용할 수 있습니다."
  - 원본 언어가 지정돼 있으면 선택한 번역 언어별 언어 팩 상태(설치됨/다운로드 필요/지원 안 함)와
    "언어 팩 준비" 버튼. 자동 감지 상태에서는 "감지된 언어의 언어 팩이 없으면 번역이 실패합니다.
    원본 언어를 지정하면 미리 준비할 수 있습니다." 안내.
- 언어 팩 준비: 뷰에 붙인 `.translationTask(configuration)`에서 `prepareTranslation()`을 호출해
  시스템 다운로드 확인 창을 띄운다. 필요한 쌍을 하나씩 처리하고 끝나면 상태를 다시 읽는다.
- 처리 시작(`startProcessing`): `apple`이고 번역 언어가 있으면
  - macOS 26 미만이면 시작하지 않고 안내.
  - 원본 언어가 지정돼 있으면 각 쌍의 상태를 확인: `unsupported`가 있으면 시작하지 않고 안내,
    `supported`(미설치)가 있으면 언어 팩 준비를 띄우고 끝난 뒤 시작.

## 오류 처리와 보존

- 언어 팩 미설치·미지원 쌍: 재시도하지 않고 해당 언어만 실패. 파일 상태에 원인과 조치를 표시.
- 번역 실패 시 기존과 같이 원문 SRT와 영상은 보존한다.
- 자막 번호·시간은 원문에서 그대로 복사하므로 `matchesTiming` 검증이 구조적으로 통과한다.

## 테스트

- SwiftPM 단위 테스트: 언어 코드 대응(`zh`→`zh-Hans`, 미지원 코드 nil), 요청 ID/여러 줄
  합치기, 순서가 섞인 결과의 재조립, 누락·빈 번역 오류, `TranslationEngine`에 주입했을 때의
  번호·시간 보존(가짜 번역 함수).
- 샌드박스 런타임 테스트(xcodebuild): macOS 26 이상이고 영어→한국어 언어 팩이 설치돼 있으면
  짧은 SRT를 실제로 번역해 번호·시간이 같고 텍스트가 바뀌었는지 확인. 설치돼 있지 않으면 건너뛴다.
- 회귀: 기존 SwiftPM 전체, Store 스크립트, 샌드박스 런타임 테스트.

## 스토어 자료

- 심사 메모: "OPTIONAL TRANSLATION"에 Apple 번역(macOS 26+, 계정 불필요, 기기 내 처리, 첫 사용 시
  시스템 언어 팩 다운로드)을 심사자 권장 경로로 추가하고, ChatGPT는 선택 사항으로 둔다.
- TestFlight 테스트 안내에 Apple 번역 항목 추가.
- 개인정보: 데이터가 기기 밖으로 나가지 않으므로 App Privacy 선언과 개인정보 매니페스트는 바꾸지 않는다.
  `docs/privacy.md`에는 Apple 번역이 기기 내에서 처리된다는 문장만 추가한다.

## 범위 밖

- 직접 배포 DMG의 Apple 번역, macOS 15의 뷰 기반 세션.
- Gemma 등 별도 LLM 런타임 번들(1.1 이후 검토).
- 번역 품질 전략 선택(`highFidelity`/`lowLatency`, macOS 26.4+)은 기본값을 쓴다.
