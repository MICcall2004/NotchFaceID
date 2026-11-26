# NotchFaceID

MacBook 노치에서 펼쳐지는 Face ID 스타일 얼굴 인식 앱. 카메라로 얼굴을 찾아 등록된 얼굴과 비교하고, 결과를 노치 애니메이션으로 보여 줍.

> **Touch ID만큼 안전하지 않습니다.** 일반 RGB 카메라라 깊이를 보지 못해, 정교한 사진·영상 위조를 완전히 막지 못합니다. sudo와 잠금 화면 연동은 옵트인이며, 비밀번호 입력은 항상 대체 경로로 남습니다. Apple Pay, 키체인, 시스템 설정의 Touch ID 창은 대체할 수 없습니다. 설계와 위험은 [docs/SYSTEM_AUTH.md](docs/SYSTEM_AUTH.md) 참고.

## 요구 사항

- macOS 14 이상
- Xcode Command Line Tools (`swiftc`)
- 카메라. 노치가 없는 Mac에서는 화면 위쪽 가장자리에서 알약 모양으로 내려옴.

## 빌드와 실행

```bash
./build.sh
open build/NotchFaceID.app
```

`build.sh`는 `build/NotchFaceID.app`을 만들고 셀프테스트를 실행. 서명이 ad-hoc이라서 다시 빌드하면 macOS가 카메라 권한을 다시 물을 수 있음.

## 사용법

메뉴는 메뉴 막대의 Face ID 아이콘이나 **노치 클릭**으로 엽음. 메뉴 막대가 꽉 차면 아이콘이 노치 뒤에 숨으므로 그때는 노치를 클릭.

1. `얼굴 등록`: 카메라 권한을 허용한 뒤 고개를 천천히 움직임. 샘플 10장이 모이면 링이 다 차고 등록이 끝남.
2. `얼굴 인식`: 4초 안에 일치하면 초록 체크, 아니면 빨간색으로 흔들림. 앱을 다시 열어도(Spotlight, `open -a NotchFaceID`) 인식이 시작됨.
3. `등록 삭제`: 저장된 얼굴 데이터를 지웁.

### 기준 조정

메뉴에 `마지막 거리 / 기준` 값이 표시됨. 거리가 기준 이하이면 통과.

- 본인인데 실패한다면 `더 느슨하게 (기준 +10%)`
- 다른 사람이 통과한다면 `더 엄격하게 (기준 −10%)`

기준 기본값 0.57은 LFW 평가에서 정했습니다. 다시 등록하면 기본값으로 돌아갑니다.

## 동작 방식

- 노치 위에 투명하고 클릭이 통과하는 패널을 띄우고, 그 안에서 SwiftUI 도형이 노치 크기에서 펼쳐짐.
- 프레임마다 Vision 랜드마크로 얼굴을 정렬해 SFace 임베딩(128차원)을 뽑고, MiniFASNet으로 사진·화면 여부를 봅니다. 두 모델 모두 Apache-2.0이며 Core ML로 변환해 앱에 들어 있습니다([Tools/models](Tools/models/README.md)).
- 등록 샘플과의 거리(1 − 코사인)가 기준 이하이고 실제 얼굴로 판정된 프레임이 3장 모이면 통과합니다. 내장 카메라만 씁니다.
- LFW 기준 정확도 99.5%, 오인식률 0.01%에서 본인 통과율 97.9%([Tools/eval](Tools/eval/README.md)). 이 Mac 카메라에서의 위조 탐지 성능은 아직 측정하지 않았습니다.

## 개인정보

- 얼굴 임베딩은 `~/Library/Application Support/NotchFaceID/faces`에 저장. sudo 설치 시 root 보호 사본을 `/Library/Application Support/NotchFaceID/faces`에 둠.
- 영상과 사진은 저장하지 않으며, 네트워크로 보내는 데이터는 없음.
- 카메라는 인식·등록 중에만 켜짐.

## 셀프테스트

```bash
build/NotchFaceID.app/Contents/MacOS/NotchFaceID --selftest
```

모델 로드와 출력 형태, 정렬 변환, 판정 규칙, 템플릿 저장·로드, AuthServer 통신을 확인합니다. 실제 얼굴 정확도는 `--eval`로 잽니다.

## 기여

브랜치 전략은 GitHub Flow. 규칙과 프로젝트 구조는 [CONTRIBUTING.md](CONTRIBUTING.md) 참고.
