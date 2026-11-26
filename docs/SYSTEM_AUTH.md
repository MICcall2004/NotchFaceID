# 시스템 인증 연동 (`sudo` PAM + 잠금 화면 해제)

> **위협 모델 안내**: MacBook 내장 FaceTime HD 카메라는 일반 RGB 카메라(IR/깊이 센서 없음)입니다.
> SFace 임베딩 + MiniFASNet 패시브 안티스푸핑 + 내장 카메라 강제 + 명시적 클릭 동의 + 인증서 해시 피닝으로 최선의 로컬 방어를 제공하지만,
> Apple Secure Enclave 기반 Touch ID와 동일한 하드웨어 보안 경계는 아닙니다.
> - **명시적 클릭 동의의 한계**: 이미 손쉬운 사용(Accessibility) 권한을 가진 프로세스는 합성 클릭(`CGEvent`)을 생성할 수 있으므로, 노치 클릭 동의는 일반 사용자 권한 프로세스의 무음 `sudo` 악용을 막는 보조 방어선입니다.
> - **잠금 해제 Keychain 항목의 한계**: 로그인 비밀번호는 Keychain(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)에 저장됩니다. `setup-codesign.sh`로 생성한 고정 서명 인증서를 사용해야 재빌드 후에도 designated requirement가 유지되며, 잠금 해제 기능을 쓰지 않는다면 비밀번호를 저장하지 않는 것이 안전합니다.
> - 모든 경로에서 기존 macOS 비밀번호 / Touch ID 폴백을 항상 유지합니다.

---

## 1. `sudo` 인증 아키텍처 (PAM ↔ AuthServer)

```
sudo (euid=0)
  └─ /etc/pam.d/sudo_local → /usr/local/lib/pam/pam_notchfaceid.so (arm64, timeout=10)
       ├─ 사전 Fail-safe: SSH / 클램쉘 닫힘 / 화면 잠금 / 비콘솔 → 즉시 PAM_IGNORE(비밀번호 폴백)
       ├─ Unix 소켓 연결: ~/Library/Caches/local.notchfaceid/auth.sock (0700 dir / 0600 sock)
       ├─ 서버 신원 검증 (예외/우회 경로 없음):
       │    - LOCAL_PEERCRED + LOCAL_PEERTOKEN → SecCodeCheckValidity
       │    - /Library/Application Support/NotchFaceID/code_requirement 필수 (root:wheel 0644)
       │      `identifier "local.notchfaceid" and certificate leaf = H"<SHA-1>"`
       │    - 번들 경로 정확히 `/Applications/NotchFaceID.app` + 앱/실행파일 root:wheel 소유 검증
       └─ 32바이트 랜덤 hex nonce 요청/응답 (상수시간 검증)
            └─ NotchFaceID.app (AuthServer)
                 ├─ LOCAL_PEERCRED uid==0 확인
                 ├─ root 보호 템플릿 필수 확인 (/Library/Application Support/NotchFaceID/faces 및 상위 경로 전체 root 소유·비쓰기 검증)
                 ├─ 노치에 "sudo · ttysXXX" + "클릭해서 승인" 표시 (명시적 마우스 클릭 동의 필수)
                 └─ 클릭 후 Engine.authenticate(reason:timeout:) 실행 (스캔마다 root 보호 템플릿만 다시 로드, 기준은 기본값 threshold ≤ 0.57 / live ≥ 0.50보다 느슨해지지 않음)
```

### 단계별 설치·검증·되돌리기

1. **PoC 검증 (잠김 위험 없음, 자동 롤백)**
   ```bash
   ./build.sh
   ./Scripts/test-pam-poc.sh
   ```
   `log show`에 `pam_test: loaded and invoked`가 찍히면 macOS 26의 `sudo`가 `arm64` 서드파티 PAM 모듈을 정상 로드한다는 뜻입니다.

2. **로컬 코드 서명 인증서 생성 및 서명 빌드 (필수)**
   ```bash
   ./Scripts/setup-codesign.sh
   SIGN_IDENTITY="NotchFaceID Local Signing" ./build.sh
   ```

3. **`sudo` 연동 설치**
   ```bash
   ./Scripts/install-sudo.sh
   ```
   설치 스크립트가 인증서 리프 SHA-1 해시 피닝 요구사항(`certificate leaf = H"<SHA-1>"`)을 생성하고 `codesign --verify --strict`로 검증한 뒤 `/Applications/NotchFaceID.app`(`root:wheel`), 보호 템플릿(`root:staff 0640`), LaunchAgent, `/etc/pam.d/sudo_local`을 설치합니다.

4. **롤백 / 완전 제거**
   ```bash
   ./Scripts/uninstall-sudo.sh          # PAM 및 LaunchAgent만 제거
   ./Scripts/uninstall-sudo.sh --purge  # /Applications 앱과 보호 템플릿까지 삭제
   ```

---

## 2. 잠금 화면 해제 (`Sources/ScreenUnlock.swift`)

macOS 26에서 `authorizationdb`(`system.login.screensaver`)에 커스텀 Authorization Plugin을 넣으면 잠금 화면 멈춤·Touch ID 손상·로그인 키체인 미해제 위험이 큽니다.
대신 오픈소스 Mac Face Unlock 앱들과 동일하게 **옵트인 유저 공간 방식**을 사용합니다:

- `com.apple.screenIsLocked` / `screensDidWakeNotification` 감지 (잠금 직후 3초 dwell, 잠금당 최대 2회, 클램쉘 체크)
- **보호 템플릿 필수**: `sudo`와 동일하게 `/Library/Application Support/NotchFaceID/faces`(`root:staff 0640`)가 변조 방지 상태(`TemplateStoragePolicy.isTamperProtected`)가 아니면 활성화·스캔·입력을 모두 거부합니다.
- **설정 변조 방어**: sudo와 잠금 해제는 스캔마다 root 보호 템플릿(`isTamperProtected`)만 다시 로드하고, `UserDefaults` 기준을 기본값(`threshold ≤ 0.57`, `live ≥ 0.50`)보다 느슨하게 쓰지 않습니다. 그래서 같은 uid 프로세스의 `defaults write`나 사용자 사본 바꿔치기로 우회할 수 없습니다. 메뉴의 직접 스캔만 사용자 사본과 넓은 상한(`0.64` / `0.30`)을 씁니다.
- **알림 위조 방지**: 알림 수신 시, 스캔 시작 직전, 그리고 **비밀번호 입력 직전**마다 `CGSessionCopyCurrentDictionary()`의 `CGSSessionScreenIsLocked == true`와 `NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"`를 재확인하여 가짜 알림으로 다른 앱 입력란에 비밀번호가 입력되는 공격을 차단합니다.
- 얼굴 + 라이브니스 통과 시 Keychain(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)에서 로그인 비밀번호를 읽어 `CGEvent`로 입력 후 버퍼 즉시 제로화.
- **잠김 위험 0**: 앱을 끄거나 메뉴에서 `잠금 화면 얼굴 해제`를 해제하면 즉시 중단되며, 비밀번호와 Touch ID가 그대로 동작합니다.
- **판정 기록(옵트인)**: 메뉴의 `판정 기록 (CSV)`를 켜면 `~/Library/Application Support/NotchFaceID/frames.csv`(`0600`)에 프레임별 거리·라이브니스·각도·EAR·결과만 기록합니다(이미지·임베딩 미저장).
- 진단 로그 확인:
  ```bash
  log show --last 5m --predicate 'subsystem == "local.notchfaceid.screenunlock"' --info
  ```
