# 기여 방법

브랜치 전략은 [GitHub Flow](https://docs.github.com/en/get-started/using-github/github-flow)입니다.

## 규칙

- `main`은 항상 빌드되고 실행되는 상태를 유지합니다. `main`에 직접 커밋하지 않습니다.
- 모든 변경은 `main`에서 딴 짧은 브랜치에서 하고, Pull Request로 합칩니다.

## 순서

1. `main`을 최신으로 받고 브랜치를 만듭니다.

   ```bash
   git switch main && git pull
   git switch -c feat/hotkey
   ```

2. 커밋하고 푸시합니다. 푸시 전에 `./build.sh`가 통과해야 합니다.
3. `main`으로 Pull Request를 엽니다.
4. 확인이 끝나면 합치고 브랜치를 지웁니다.

## 브랜치 이름

`종류/짧은-설명` 형식입니다.

| 종류 | 용도 |
| --- | --- |
| `feat/` | 기능 추가 |
| `fix/` | 버그 수정 |
| `chore/` | 구조, 빌드, 문서 |

## 프로젝트 구조

```
Sources/
  main.swift          진입점, --selftest, --eval
  AppDelegate.swift   노치 패널, 메뉴, sudo 승인 클릭
  NotchView.swift     UI 상태, 노치 애니메이션
  Matching.swift      카메라, 등록·인식 판정, authenticate(), TemplateStore
  FaceAlign.swift     랜드마크 정렬, 모델 입력 crop
  FaceModels.swift    SFace 임베딩, MiniFASNet 위조 탐지
  Eval.swift          LFW 정확도 평가
  AuthServer.swift    PAM 모듈과 통신하는 Unix 소켓 서버
  ScreenUnlock.swift  잠금 화면 해제(키체인 + 자동 입력, 옵트인)
PAM/                  sudo용 PAM 모듈, 로드 확인용 pam_test
Resources/
  Info.plist          번들 정보, 카메라 권한 문구
  Models/             변환된 Core ML 모델과 라이선스
Scripts/              sudo 설치·제거, 서명 인증서, PAM PoC
Tools/models/         모델 내려받기·변환
Tools/eval/           평가 방법과 결과
docs/SYSTEM_AUTH.md   sudo·잠금 화면 연동 설계
build.sh              앱 + PAM 모듈 빌드, 셀프테스트
```
