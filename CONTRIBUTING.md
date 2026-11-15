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
  main.swift         진입점, --selftest
  AppDelegate.swift  노치 패널, 메뉴와 동작
  NotchView.swift    UI 상태, 노치 애니메이션
  Matching.swift     카메라, 얼굴 매칭
Resources/
  Info.plist         번들 정보, 카메라 권한 문구
build.sh             build/NotchFaceID.app 빌드 + 셀프테스트
```
