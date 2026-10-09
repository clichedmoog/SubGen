# ChatGPT 번역 연동 — 2026-10-10

OpenAI Docs를 ego-browser로 직접 확인했습니다. 사용자가 **무료 오픈소스** 배포를
선택했고 앱 소스에 MIT 라이선스를 적용했습니다. OAuth·계정별 모델 목록·번역 UI와
네이티브 Responses 클라이언트를 구현했습니다. **실제 사용자 로그인·추론은 아직
검증하지 않았으며** `translationBackendVerified`는 false입니다. 공개 저장소에 이
변경을 공개 기본 브랜치에 병합하지 않았습니다. 영문 리스팅과 개인정보 선언은
콘솔에 저장했습니다. 실제 서비스 검증은 계속 대기입니다.

## 구현과 로컬 검증

- `ChatGPTLoopback`: IPv4 loopback 전용·30분 제한·한 번만 받는 콜백. state, 중복
  query, redirect와 returning client ID를 검증한 뒤 코드를 교환합니다.
- `ChatGPTIdentity`: Security/CryptoKit RS256·ES256 서명, JWKS, issuer, audience/azp,
  만료/iat/nbf, nonce를 검증합니다. 실제 계정의 subject/issuer가 일치해야 재연결합니다.
- `ChatGPTCredentialStore`: macOS Keychain에 토큰을 저장합니다. 이메일이 같아도
  issued client ID가 다른 등록을 구분합니다. 설치 UUID·선택 모델 등 비밀 아닌 설정만
  UserDefaults에 저장합니다. 발급 후 교환 실패 시 provisional client ID를 재사용합니다.
- `ChatGPTAccountService`: refresh를 등록별 single flight로 실행하며 회전된 토큰을
  함께 저장합니다. 로그아웃/재로그인과 겹친 응답은 revision 검사로 거부합니다.
  로그아웃은 로컬 토큰 삭제와 서버 revoke 확인 여부를 따로 표시합니다.
- `ChatGPTSubtitleClient`: `/v1/models`의 list 모델을 서버 순서로 표시하고 고른 slug로
  `/v1/responses`에 직접 `store:false`, `stream:true`, 배열 input을 보냅니다.
  기본 AsyncBytes.lines가 빈 줄을 생략하여 SSE가 합쳐지는 문제를 네트워크 시험에서
  발견했고, 빈 줄·CRLF·UTF-8을 보존하는 byte parser로 수정했습니다.
- 사용량 제한 후 새 요청을 멈춥니다. Manage usage에서 한도를 확인한 뒤 명시적으로
  새로고침하여 재시도할 수 있습니다. 일시적 503/rate-limit 오류만 최대 3회,
  지연을 두고 다시 요청합니다. 무단계정·한도 오류는 반복하지 않습니다.
- `response.completed`와 원문 자막 개수·번호·타이밍 검증을 모두 통과해야 결과를
  저장합니다. 취소·잘린 결과·실패 이벤트·끊긴 스트림에서는 원본 SRT를 보존합니다.
- 모델 목록과 번역 대상 계정을 처리 시작 때 고정합니다. 자동은 서버 목록 첫 모델을
  뜻하며 최신 출시/번역 품질을 보장하지 않습니다. 별도 CLI나 API 키는 필요 없습니다.

로컬 검증: SwiftPM 143개 통과(기존 opt-in 4개 건너뜀), 그중 ChatGPT 시험 10개.
PKCE 표준 벡터, RSA/EC 실제 난수 키의 JWT, 위조 콜백, scope 거부, refresh 경쟁,
모델/요청 wire schema, SSE 완료/실패, 사용량 pause를 합성 응답으로 검증했습니다.
서명된 Debug 앱 호스트 4개 통과: 실제 전사·컨테이너·북마크와 loopback/Keychain.
실제 OpenAI 인증·계정별 모델 제공·SRT 추론·refresh·revocation은 별도 검증이 필요합니다.

첫 실제 확인은 스토어 앱의 Continue with ChatGPT에서 사용자가 직접 로그인하고
플랜 사용 권한을 승인해야 합니다. 이 동의 없이 기존 Codex 인증을 가져오지 않습니다.

## 앱에 적용할 수 있는 구조

음성 전사는 앱에 포함된 Whisper·FFmpeg로 처리하고, 번역할 SRT 텍스트만
Responses API로 보냅니다. 외부 Codex 설치나 별도 API 키 없이 사용자의 허가를 받은
ChatGPT 플랜을 사용할 수 있는 공식 경로가 있습니다. 로그인으로 기존 ChatGPT
대화에 접근할 수 있는 것은 아닙니다.

현재 안내는 오픈소스·로컬 호스팅 앱용입니다. 사용자가 무료 오픈소스 방침을
확정했으며 앱 소스에는 MIT 라이선스를 적용했습니다. 유료 또는 원격 호스팅 앱은
별도 신청 안내가 있습니다. FFmpeg·Whisper의 기존 라이선스와 FFmpeg 번들 대응 소스
배포 의무는 앱 소스 라이선스와 별도로 확인합니다.

- [Quickstart 및 대상](https://developers.openai.com/siwc/quickstart)
- [오픈소스 경로와 유료 앱 신청 안내](https://developers.openai.com/siwc/token-sharing-open-source)
- [상용 client ID 신청 안내](https://developers.openai.com/siwc/request-client-id)

## 구현 순서

1. 설치마다 고정한 비식별 `ext_agent_host_id`를 보관합니다. UUID URI를 사용할 수
   있으며 재로그인이나 앱 재실행마다 새 호스트를 만들지 않습니다.
2. macOS 시스템 브라우저로 PKCE OAuth를 시작합니다. 첫 등록은
   `dynamic_agent_client`; 돌아온 실제 `client_id`를 검증·보관하여 다음 로그인에
   재사용합니다. state·nonce·PKCE는 매 시도 새로 생성합니다.
3. 문서가 요구하는 `http://127.0.0.1:<port>/auth/callback` 리스너를 먼저 시작합니다.
   샌드박스의 `network.server` 권한이 추가로 필요합니다. 리스너는 loopback에만
   바인딩하고 로그인 완료·취소·시간 초과 때 종료합니다. URI의 포트 외 부분과
   해당 시도의 code 교환 URI가 정확히 일치해야 합니다.
4. JWKS 서명과 issuer·audience·만료·nonce를 검증한 ID token만 수락합니다.
   `chatgpt.tokens.use.direct` 등 실제 반환 scope를 확인합니다. 사용자·workspace별
   등록을 분리하고 검증 전에는 기존 활성 계정의 인증을 교체하지 않습니다.
5. access·refresh·ID token은 Keychain에 보관합니다. 인증 URL·로그·진단·소스에
   토큰을 기록하지 않습니다. 갱신을 직렬화하고 회전된 토큰과 만료를 함께 저장합니다.
   로그아웃 때 세션 취소 결과와 로컬 삭제를 구분합니다.
6. OAuth 토큰으로 `/v1/models`를 읽어 `visibility == "list"`인 항목을 서버 순서로
   표시합니다. `display_name`은 화면에, `slug`는 실제 요청에 사용합니다.
   계정 변경·로그인 때 새로 받아 고정된 구형 모델 목록에 의존하지 않습니다.
   이 카탈로그만으로 어떤 모델이 번역 품질상 가장 최신/최선인지 단정하지 않습니다.
7. `/v1/responses`로 SRT 묶음을 전송합니다. `store:false`, `stream:true`, 배열형
   `input`을 사용합니다. 기존 자막 번호·개수·타이밍 검증과 실패 시 파일 보존을
   재사용합니다. `response.completed`를 받은 경우만 성공으로 인정합니다.
8. 계정/플랜 사용 상태·첫 동의 안내·사용량 관리 링크를 제공합니다. 사용량 제한,
   권한 거절, 불완전 스트림, 네트워크 중단을 구분합니다. 사용량 부족을 다른 과금
   경로로 자동 전환하지 않습니다. Plus 사용량은 다른 연동 앱과 공유될 수 있습니다.
9. 실제 로그인·갱신·로그아웃, 현재 계정 모델 목록, 시험 SRT 번역과 취소를 확인한
   뒤 `translationBackendVerified`를 갱신합니다. 개인정보 문구와 심사자의 로그인
   접근 방법도 이때 확정합니다. Preview라는 점과 App Store 심사 통과 여부는 별개입니다.

## 제한과 검증

이 경로는 텍스트 번역에 적합해 보이지만 SIWC로 음성 전사 API·Files 업로드 API를
사용할 수는 없습니다. 기존 Whisper 전사는 계속 로컬로 실행합니다. 모델·계정·지역·
workspace 정책에 따라 권한이 달라질 수 있으므로 모든 ChatGPT 계정에서 사용 가능하다고
광고하지 않습니다. `max_output_tokens`, `temperature`, `previous_response_id` 등의
일반 Responses 옵션도 이 preview HTTP 경로에서는 허용되지 않습니다.

- [등록·로그인 계약](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [계정·갱신·보관·사용량](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [모델 목록과 추론](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [실패 처리](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)
- [Preview 제한](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [사용 상태와 동의 화면](https://developers.openai.com/siwc/ui-ux-guidelines)
