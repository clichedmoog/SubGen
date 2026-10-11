# Mirroring Blue app icon

Opus xhigh의 두 말풍선·꼬리·자막 모양을 유지하고 iPhone 미러링의 푸른 계열과 투명한 겹침을 참고한 아이콘입니다.

- `AppIcon.svg`: 64–1024px ICNS 원본.
- `AppIcon-32.svg`, `AppIcon-16.svg`: 작은 크기 전용 원본.
- `AppIcon-1024.png`: 정적 ICNS 미리보기.
- `icon-composer-layers/`: 효과를 굽지 않은 원본 레이어. 좌표는 기존 1024px ICNS 캔버스 기준입니다.
- `AppIcon.icon`: 실제 Icon Composer 문서. 배경과 세 그룹(자막, 앞 유리, 뒤 말풍선)을 시스템이 렌더링합니다. Icon Composer에서 열어 편집할 수 있습니다.

정적 ICNS를 재생성하려면 프로젝트 루트에서 `bash scripts/generate-app-icon.sh`를 실행합니다. 16–1024px의 모든 물리 크기를 포함한 9개 표현을 검증합니다. 실제 macOS 27.2 렌더링에서 회색 둘레를 만들었던 ic05 대신 같은 32px의 ic11을 사용합니다.

네이티브 아이콘은 Xcode 27 이상으로 `bash scripts/compile-app-icon.sh /path/to/SubGen.app`을 실행하면 컴파일됩니다. 밝은·어두운·색조 모드의 `IconImageStack`을 검증한 뒤 `Assets.car`와 `CFBundleIconName`을 연결하며, `build-dmg.sh`가 서명 전에 이 작업을 수행합니다. 앱의 최소 배포 버전은 14.0입니다.

`AppIcon.icon/Assets/`는 원본 타일의 (100,100)–(924,924)를 마스킹 전 1024px 캔버스로 매핑한 동일한 도형입니다. 배경 마스크·반사·굴절·투명도는 시스템이 처리합니다. `design/icon-colour-revision/build-native-icon.py`에 좌표 변환과 초기 재질 설정을 보관합니다. 색상 시안 생성기는 같은 디렉터리의 `IconColourRevision/generate_icon.py`에 있습니다.

참고: [Apple app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons), [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).
