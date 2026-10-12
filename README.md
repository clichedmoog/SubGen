# SubGen — Subtitle Maker & Translator

Free, open-source macOS app that turns speech in your videos and audio into subtitles on your Mac,
then translates them if you want. [한국어 안내는 아래에 있습니다.](#한국어)

- **On-device transcription** with [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and Metal.
  Choose a speech model from Tiny to Large v3 Turbo; the spoken language can be detected automatically.
- **Subtitles that start with the speech.** A Silero voice-activity model trims each cue to the
  speech it belongs to, so subtitles don't appear over intro music or silence.
- **SRT files or embedded tracks.** Save an `.srt` next to the media, or embed the subtitle track into
  MP4/MOV/M4V, MKV or WebM. The original file is only replaced after the new file passes validation.
- **Translation into 9 languages** (Korean, Japanese, English, Chinese, French, German, Spanish,
  Portuguese, Russian). Numbering and timings are kept exactly; only the text is translated.
  - **Apple Translation** — on-device and free, no account. macOS asks once to download each language.
    Requires macOS 26 or later.
  - **ChatGPT** — sign in with your ChatGPT plan (Mac App Store edition).
  - **Claude Code or Codex CLI** — uses an installed, signed-in CLI (direct-download edition).
- Queue many files, cancel any time, and reuse existing subtitles instead of transcribing again.

The interface is currently in Korean.

## Download

| Edition | Where | Translation options |
|---|---|---|
| Mac App Store | In review — the link will be added after approval | Apple Translation, ChatGPT |
| Direct download | [GitHub Releases](https://github.com/clichedmoog/SubGen/releases/latest) (`SubGen-<version>-arm64.dmg`, notarized by Apple) | Apple Translation, Claude Code / Codex CLI |

Requirements: a Mac with Apple Silicon and macOS 14 or later. Apple Translation needs macOS 26 or later.
Speech models need between about 80 MB (Tiny) and 3 GB (Large v3) of disk space.

On first launch the direct-download edition offers to install FFmpeg, FFprobe and the whisper.cpp
command-line tool, then downloads the speech model you pick. The App Store edition already includes
the tools and only downloads the model.

## Using SubGen

1. Click **시작 설정** (Start setup) and install the tools and a speech model.
2. Drop audio or video files onto the window, or click **파일 선택** (Choose files).
3. In **작업 설정** (Work settings) choose the spoken language (or 자동 감지 for automatic detection)
   and the output: SRT file or subtitles embedded in the video.
4. To translate, choose a translation method and tick the target languages.
5. Click **처리 시작** (Start processing). Subtitles are saved next to each file as `name.<language>.srt`.

Work on copies when you embed subtitles: the app replaces the original video after validating the new one.

## Privacy

Audio and video never leave your Mac. With Apple Translation, subtitle text also stays on your Mac.
With ChatGPT, only subtitle text and translation instructions go to OpenAI under your account; with
Claude Code or Codex, the CLI you installed sends them to its provider. SubGen has no analytics,
advertising or developer server. Details: [Privacy Policy](docs/privacy.md).

## Building from source

```sh
swift build
swift test
```

The project is built with Xcode 27 and the macOS 27 SDK. The Mac App Store target is generated with XcodeGen from
`project.yml`. Release packaging, notarization and store workflows are described in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Support and license

Questions and bug reports: [GitHub Issues](https://github.com/clichedmoog/SubGen/issues). Issues are
public — don't post account credentials or private media.

SubGen is released under the [MIT License](LICENSE). FFmpeg (LGPL build in the App Store edition, with
its source included in the app), whisper.cpp and the speech models keep their own licenses.

---

## 한국어

SubGen은 영상·음성 속 말소리를 Mac에서 바로 자막으로 만들고, 원하면 번역까지 하는 무료 오픈소스 macOS 앱입니다.

- **기기 내 전사:** whisper.cpp와 Metal로 처리합니다. Tiny부터 Large v3 Turbo까지 모델을 고를 수 있고 말하는 언어를 자동으로 감지합니다.
- **말이 시작될 때 뜨는 자막:** 음성 구간 감지(Silero VAD)로 각 자막을 실제 음성에 맞춰, 앞부분 음악이나 침묵 위에 자막이 뜨지 않게 합니다.
- **SRT 파일 또는 영상에 자막 포함:** 원본 옆에 `.srt`를 저장하거나 MP4/MOV/M4V, MKV, WebM 영상에 자막 트랙을 넣습니다. 새 파일 검증을 통과한 뒤에만 원본을 바꿉니다.
- **9개 언어 번역:** 한국어·일본어·영어·중국어·프랑스어·독일어·스페인어·포르투갈어·러시아어. 자막 번호와 시간은 그대로 두고 문장만 번역합니다.
  - **Apple 번역:** 기기 내 처리, 무료, 계정 불필요. 언어마다 처음 한 번 macOS가 다운로드를 묻습니다. macOS 26 이상.
  - **ChatGPT:** ChatGPT 플랜으로 로그인 (App Store판).
  - **Claude Code / Codex CLI:** 설치·로그인된 CLI 사용 (직접 배포판).

### 다운로드

- **Mac App Store:** 심사 중이며 승인 후 링크를 추가합니다.
- **직접 배포판:** [GitHub Releases](https://github.com/clichedmoog/SubGen/releases/latest)의 `SubGen-<버전>-arm64.dmg` (Apple 공증 완료).

요구 사항: Apple Silicon Mac, macOS 14 이상 (Apple 번역은 macOS 26 이상). 음성인식 모델은 약 80MB(Tiny)~3GB(Large v3)의 공간이 필요합니다. 직접 배포판은 첫 실행 때 FFmpeg·FFprobe·whisper.cpp 도구 설치를 안내합니다.

### 사용 방법

1. **시작 설정**에서 도구와 음성인식 모델을 설치합니다.
2. 파일을 창에 끌어 놓거나 **파일 선택**을 누릅니다.
3. **작업 설정**에서 말하는 언어(또는 자동 감지)와 출력 방식(SRT 파일 / 영상에 자막 포함)을 고릅니다.
4. 번역하려면 번역 방식과 대상 언어를 선택합니다.
5. **처리 시작**을 누르면 각 파일 옆에 `이름.<언어>.srt`가 저장됩니다.

영상에 자막을 포함하면 검증 후 원본 영상을 교체하므로 사본으로 작업하기를 권합니다.

### 개인정보

음성·영상 파일은 Mac 밖으로 나가지 않습니다. Apple 번역을 쓰면 자막 텍스트도 Mac에서만 처리합니다. ChatGPT를 쓰면 자막 텍스트와 번역 지시만 사용자 계정으로 OpenAI에 보내고, Claude Code·Codex를 쓰면 설치한 CLI가 해당 서비스로 보냅니다. 분석·광고 SDK나 개발자 서버는 없습니다. 자세한 내용은 [개인정보 처리방침](docs/privacy.md)을 참고하세요.

### 문의·라이선스

문의와 버그 신고는 [GitHub Issues](https://github.com/clichedmoog/SubGen/issues)로 해주세요(공개 게시판이므로 계정 정보나 개인 영상은 올리지 마세요). 앱 소스는 [MIT 라이선스](LICENSE)이며 FFmpeg, whisper.cpp, 음성인식 모델은 각자의 라이선스를 따릅니다.
