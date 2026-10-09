# Privacy Policy / 개인정보 처리방침

**SubGen — Subtitle Maker & Translator**  
Developer: Myeongseok Seo · Last updated: October 10, 2026

## English

### Local transcription and file access

SubGen transcribes audio on your Mac with whisper.cpp and processes media with FFmpeg and FFprobe. Audio and video files are not uploaded for transcription or translation. The Mac App Store version uses App Sandbox and accesses the files and output folders you authorize. Generated subtitles and videos are saved on your Mac. Embedding subtitles may replace the original video after the replacement passes validation.

### Optional ChatGPT translation

Translation is optional. Transcription works without a ChatGPT account. If you choose translation, you authorize an eligible ChatGPT account through OpenAI. Subtitle text, the target language and translation instructions are sent directly to OpenAI. OpenAI also handles account authentication, account and authorization identifiers, the email address used for login, and a random identifier for this app installation. These requests are associated with your authorized account and support authentication, translation and service security. Translation uses your ChatGPT plan or credits and is subject to OpenAI's availability and usage limits.

Requests disable response storage with `store: false`. This does not mean that OpenAI retains no data, or override your account's data controls, OpenAI's service terms or its privacy practices. See [OpenAI's privacy policy](https://openai.com/policies/privacy-policy/), [data controls](https://help.openai.com/en/articles/7730893-data-controls-faq), and the [Sign in with ChatGPT documentation](https://developers.openai.com/siwc).

SubGen has no developer-operated translation server, advertising, analytics SDK or automatic diagnostic-upload service. The developer does not receive your media, subtitles or ChatGPT credentials through app use.

### Credentials and local storage

OAuth credentials are stored in the app's macOS Keychain item. Preferences, selected account registration, the random installation identifier, and file/folder access bookmarks are stored locally. Disconnecting ChatGPT removes local credentials and attempts to revoke the connection with OpenAI. The app reports if server revocation could not be confirmed; you can also manage connected apps in your OpenAI account. Local registration information may remain to reconnect the same account.

Speech models and diagnostic logs are stored locally. Logs can contain file paths and tool error messages. They rotate at approximately 5 MB. Nothing automatically sends these logs to the developer. Review logs and remove private information before sharing them for support. Removing the app may leave Keychain items, downloaded models, preferences or output files; remove those separately if desired.

### Downloads and other distribution channels

Speech model data is downloaded from Hugging Face and its delivery networks. Download providers receive ordinary network/request metadata, such as IP addresses. The Mac App Store version includes its executable media tools. The direct-download version can additionally obtain tool archives from GitHub and OSXExperts and uses separately installed Claude Code or Codex for translation. Those tools and their configured providers have their own authentication, network, telemetry and retention practices.

### Support and changes

For questions, use [SubGen's GitHub Issues](https://github.com/clichedmoog/SubGen/issues). Issues are public; do not include passwords, authorization tokens or private media/subtitles. Information you choose to submit is handled by GitHub and is visible to the developer and other readers. This policy will be updated here when the app's data practices change.

---

## 한국어

### 로컬 전사와 파일 접근

SubGen은 whisper.cpp로 이 Mac에서 음성을 전사하고 FFmpeg·FFprobe로 영상을 처리합니다. 전사와 번역을 위해 음성·영상 파일을 업로드하지 않습니다. Mac App Store 버전은 App Sandbox에서 사용자가 허용한 파일과 출력 폴더에 접근합니다. 자막과 처리한 영상은 Mac에 저장됩니다. 자막 포함을 선택하면 검증을 통과한 결과 영상으로 원본을 교체할 수 있습니다.

### 선택적 ChatGPT 번역

번역은 선택 사항이며 전사는 ChatGPT 계정 없이 사용할 수 있습니다. 번역을 선택하면 OpenAI를 통해 적격 ChatGPT 계정의 사용 권한을 허용합니다. 자막 텍스트, 대상 언어와 번역 지시를 OpenAI로 직접 보냅니다. 계정 인증·권한 식별자, 로그인에 사용하는 이메일 주소와 앱 설치별 무작위 식별자도 OpenAI가 처리합니다. 이 요청은 인증, 번역 및 서비스 보안을 위해 허용한 계정에 연결됩니다. 번역은 ChatGPT 플랜이나 크레딧을 사용하며 OpenAI의 제공 범위와 사용량 제한이 적용됩니다.

번역 요청에는 `store: false`를 설정합니다. 이 설정은 OpenAI가 어떤 데이터도 보관하지 않는다는 뜻이 아니며, 계정의 데이터 제어 설정·서비스 약관·개인정보 처리방침을 대체하지 않습니다. 위 영문 항목의 OpenAI 링크를 참고해주세요. SubGen에는 개발자가 운영하는 번역 서버, 광고, 분석 SDK나 진단 자동 전송 기능이 없습니다. 앱을 사용하는 동안 개발자가 영상·음성·자막이나 ChatGPT 인증 정보를 받지 않습니다.

### 기기 내 저장과 연결 해제

OAuth 인증 정보는 앱의 macOS Keychain에 저장합니다. 환경설정, 선택한 계정 등록 정보, 설치별 무작위 식별자와 파일·폴더 접근 북마크는 기기에 저장합니다. ChatGPT 연결 해제는 로컬 인증 정보를 제거하고 OpenAI에 연결 취소를 요청합니다. 서버 취소를 확인하지 못하면 앱이 안내하며, OpenAI 계정에서도 연결된 앱을 관리할 수 있습니다. 같은 계정으로 다시 연결하기 위한 로컬 등록 정보는 남을 수 있습니다.

음성 모델과 진단 로그도 로컬에 저장합니다. 로그에는 파일 경로나 도구 오류가 포함될 수 있으며 약 5 MB에서 순환합니다. 로그를 자동으로 개발자에게 보내지 않습니다. 지원을 위해 공유하기 전 개인정보를 제거해주세요. 앱 삭제 후에도 Keychain 항목, 모델, 환경설정이나 결과 파일이 남을 수 있으므로 필요하면 별도로 삭제해주세요.

### 다운로드와 문의

음성 모델은 Hugging Face 및 전송망에서 다운로드하며 제공자는 IP 주소 등 일반적인 요청 정보를 받을 수 있습니다. 스토어 버전에는 실행 도구가 포함됩니다. 직접 배포 버전은 GitHub·OSXExperts에서 도구를 다운로드할 수 있고, 별도로 설치한 Claude Code·Codex로 번역합니다. 해당 도구와 서비스의 인증·통신·진단·보관 정책은 별도로 적용됩니다.

문의는 [SubGen GitHub Issues](https://github.com/clichedmoog/SubGen/issues)를 이용해주세요. 이슈는 공개되므로 비밀번호·토큰·개인적인 영상이나 자막을 올리지 마세요. 직접 올린 내용은 GitHub가 처리하며 개발자와 다른 사용자가 볼 수 있습니다. 앱의 처리 방식이 달라지면 이 문서를 업데이트합니다.
