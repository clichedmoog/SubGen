# SubtitleGen 안정화

- [x] CPU 아키텍처에 맞는 FFmpeg/FFprobe 탐색·실행 검증
  - 도구 검사와 실행 경로 통일, ARM64/Intel 자동 다운로드와 배포 빌드 반영
- [x] 외부 프로세스 멈춤 해결
  - stdout/stderr 동시 수집, 타임아웃, 전사·번역·설치 취소
- [x] 언어 감지·청크 처리 수정
  - 실제 샘플/청크 WAV 추출, 감지 신뢰도 확인, 원래 영상 시간 복원
- [x] 실패 상태와 파일 보존
  - 내장 자막 추출, 번역 구조 검증, 실패 전달, 안전한 영상 교체, 실패 시 SRT 보존
- [x] 회귀 테스트·빌드·시험 음성 검증 및 사용 문서 갱신

## 검증 결과 (2026-10-09, Apple M5 Pro)

- 회귀 테스트 112개 통과 (Whisper 모델 테스트 포함, 실패·건너뜀 없음)
- ARM64 정적 FFmpeg/FFprobe 다운로드·SHA256·실행 검증
- 실제 Whisper 자동 언어 감지와 전사, 30분 경계를 넘는 자막 시간 복원
- 내장 자막 추출, 실패 시 원본/SRT 보존, 기존 ASS 트랙 형식 보존
- Claude Code와 Codex CLI 각각 시험 SRT 1개를 한국어로 번역하고 구조 검증
- 릴리스 빌드 성공, 개발용 앱의 ARM64 실행 파일·도구 및 코드 서명 검증

개발용 앱: `build/SubtitleGen-dev.app` (별도 bundle ID, 기존 앱 설정과 분리).
로그: `~/Library/Logs/SubtitleGen.log`.

## 배포 준비 (2026-10-09)

- [x] macOS 14용 ARM64 Whisper 정적 빌드·Metal 전사 검증 (사용자 빌드 도구 불필요)
- [x] 첫 실행 설치 안내와 도구·모델 일괄 설치, 재시도·중단
- [x] 사전 빌드 Whisper ZIP 설치의 SHA256·개발자 서명·실행 검증
- [x] Claude Opus로 같은 워크트리에서 앱 아이콘 제작, 표준 ICNS 크기·미리보기 검증
- [x] 개인 팀 Myeongseok SEO에 App ID와 App Store Connect 레코드 등록
  - Subtitle Maker & Translator / macOS / English (U.S.) / Apple ID 6820884731
- [x] 도구 미포함 경량 앱·DMG Developer ID 서명, 실제 DMG 마운트와 서명·아이콘 검증
- [x] 설치 실패·취소·기존 파일 보존을 포함한 121개 테스트 통과 (실제 정적 Whisper 검증 포함)
- [x] Xcode 로그인 계정으로 Whisper·앱·DMG Apple 공증
  - 앱과 DMG 티켓 부착 및 Gatekeeper의 Notarized Developer ID 검증 통과.
  - Whisper 단독 실행 파일은 온라인 공증 티켓 검증 통과. 공개 ZIP과 바이너리 SHA256 유지.
  - notarytool 프로필이 없으면 Xcode 계정을 사용하는 패키징 경로 추가. 처리 중 아카이브의 재개 지원.
- [x] 검증된 Whisper ZIP을 다운로드 URL에 게시
  - tools-2026.10.09 사전 릴리스 공개 완료. 로그인 없는 다운로드와 앱 설치 코드의 SHA256·개발자 서명·실행 검증 통과.
  - https://github.com/clichedmoog/SubGen/releases/tag/tools-2026.10.09
- [ ] App Store 제출용 빌드·스토어 정보·심사 준비 (현재 산출물은 Developer ID DMG)
  - [x] 공용 apple-app 스킬 3개 연결, 영문 원문·콘솔 상태·준비 자료 추출/검사 도구
  - [x] Mac 스크린샷 합성·지원/개인정보 초안·단계별 출시 기록
  - [x] Mac App Store용 XcodeGen 앱 타깃·ARM64 번들 도구·샌드박스·컨테이너 저장
  - [x] 서명된 앱 내부 FFprobe/FFmpeg/Whisper·Metal·자동 감지·SRT·컨테이너 북마크 시험
  - [x] 모델의 URLSession 다운로드·취소·오류·기존 파일 보존, 외부 CLI 설치 UI 제거
  - [x] 개발 서명 Release 실제 앱의 외부 폴더 권한·재실행·SRT 저장·영상 교체 검증
  - [x] Sign in with ChatGPT 공식 연동 조건·OAuth·동적 모델 목록·사용량 처리 조사
  - [x] 무료 오픈소스 방침 확정·앱 MIT 라이선스·스토어 ChatGPT OAuth/동적 모델/번역 연결
  - [ ] 실제 ChatGPT 로그인·갱신·연결 취소·현재 계정 모델 목록·SRT 번역 검증
  - [x] 최종 개인정보 매니페스트 검토와 App Privacy 게시
  - [x] 스토어용 FFmpeg LGPL 소스 빌드·대응 소스/레시피 포함과 패키지 검증
  - [x] 실제 스크린샷 3장·공개 URL·심사 연락처·개인정보 선언·스토어 서명 패키지
  - [ ] 연령/권리 선언 최종 확인과 실제 번역·배포판 테스트 후 정식 심사
  - [x] 내부 TestFlight 1.0 (3) 업로드·처리 완료·테스트 그룹 배포·What to Test 저장
  - [ ] 계정 소유자 초대 수락·이 Mac 설치 (클라이언트 확인 완료, 현재 초대됨)
  - 상세 상태: `Store/releases/2026-10-10.md`, `python3 Store/scripts/store.py status`

## 최신 번역 모델과 아이콘 비교 (2026-10-09)

- [x] 기존 Claude 아이콘 워커 종료
- [x] Luna xhigh / Astra medium / Opus xhigh / Opus max의 독립 서브 워크트리 시작
- [x] 애플 최신 macOS·Mac App Store 아이콘 조사 기반 후보 4종 수집·비교
  - `design/icon-comparison/comparison.png`, 각 PNG·ICNS·SVG·보고서와 검증된 실행 설정 보관. 추천: Opus xhigh.
  - 원본 서브 워크트리 4개 보존, 완료한 워커 터미널 종료.
- [x] Claude의 날짜 고정 모델을 최신 계열 별칭으로 전환하고 저장된 설정 이전
- [x] Codex 권장 모델 자동 선택과 Sol/Luna/Astra 직접 선택, 사용자 설정 유지 모드 제공
- [x] 실제 Opus·Sonnet·Codex 자동·Luna 번역과 전체 128개 테스트 통과 (실패·건너뜀 없음)
- [x] 번역 모델 변경을 반영한 DMG 재생성·서명·Apple 공증 검증
- [x] Opus xhigh 형태를 선택하고 Apple Dock 참고 색상 3종 비교 후 Mirroring Blue 적용
- [x] Icon Composer 네이티브 Liquid Glass 연결, 밝은·어두운·색조 레이어 컴파일 검증
- [x] 새 ICNS 재생성·원본 형태 동일성 확인, 완료한 Opus xhigh 워커 종료
- [x] 새 아이콘의 DMG 재생성·Apple 공증·직접 마운트·서명과 리소스 일치 검증

공증 완료 패키지: `dist/SubtitleGen-2026.10.09-arm64.dmg`.
이전 서명 전용 패키지는 `dist/SubtitleGen-2026.10.09-arm64-signed.dmg`에 보존.
Whisper 설치 파일: `dist/whisper-cli-1.8.4-macos14-arm64.zip`.

## 진행 표시 수정 (2026-10-10)

- [x] 전사 후 번역/내장 활성화·전사 언어 변경 시 큐와 진행률 초기화
- [x] 파일별 전사·번역·저장 완료를 합산, 병렬 번역 전에 전체 100%로 표시되는 오류 수정
- [x] 파일별 전사 시간·청크, 언어별 검증된 번역 자막 개수·묶음 표시
- [x] 파일 행과 전체 작업에 기본 회전 ProgressView, Dock 진행률 다시 그리기
- [x] 캐시 재사용도 완료로 표시, 원본 언어 보존/복원, 완료 뒤 늦은 콜백 무시
- [x] 진행 갱신마다 파일 북마크를 저장하던 동작 제거 (큐/원본 언어 변경 때 저장)
- [x] 실제 FFmpeg 재처리와 합성 Whisper 타임스탬프를 포함한 회귀 시험
- [x] 서명된 샌드박스에서 실제 Whisper 중간 타임스탬프 콜백 시험
- [ ] 회전 애니메이션의 최종 육안 확인 (GUI 도구 연결이 끊겨 중단)

- [x] 로그인 listener와 PKCE 만료를 30분으로 통일하고 최종 플랜 동의 안내 추가
- [x] 1.0 (4): 회귀 154개·Store 12개·Release 샌드박스 5개 및 배포 패키지 검증
- [ ] Xcode 개인 개발자 계정 재인증 후 1.0 (4) 업로드·처리·내부 그룹 배포·심사 빌드 교체

- [x] 모델 미설치 상태에서 자동 다운로드 후 전사, 다운로드 용량/비율 표시 및 실패·취소 재시도
- [x] 자동 모델 설치/파일 보존/캐시/SRT 생략 회귀: 163개 통과 (opt-in 5개 제외)
- [ ] 수정이 포함된 TestFlight 새 빌드 업로드·설치 확인 (현재 설치 1.0 (3))

- [x] 파이프 로그가 EOF까지 대기하는 문제 재현/수정, Whisper 진행률 + 처리 오디오/전체 길이 추정 표시
- [x] Whisper 빈·0초 구간 정규화 후 SRT 생성/영상 내장, 진짜 형식 오류의 원문 보존
- [x] 통합 회귀 171개 통과 (opt-in 5개 제외)

- [x] 통합 수정 Release 샌드박스 5개 및 새 App Store 패키지 서명/프로파일/도구 검증
