# 추가 감시 대상 조사

> 작성: 2026-11-19, Claude 서브에이전트 조사 결과 원문 · 범위: 기존 9개 감시 대상 외에 추가로 볼 항목, 기존 9개의 보완점
> 상위 문서: [../haetae-security-monitor.md](../haetae-security-monitor.md) · 이 파일은 참고 자료이며, 채택 여부는 상위 문서 3장·9장이 기준이다.

---

## 3줄 요약
1. 9개 대상 밖에서 추가로 볼 만한 것은 11개 묶음, 약 40개 항목입니다. 효과가 가장 큰 것은 다섯 가지입니다. ① 숨김·임시 폴더에 있는 ad-hoc 서명 실행 파일과 Apple 이름을 흉내 낸 항목 ② authd 로그에 남는 osascript의 관리자 권한 요청 ③ XProtect 상태·탐지 기록과 보안 데이터 자동 업데이트 설정 ④ 계정·admin 그룹·루트 인증서·DNS/프록시 변화 ⑤ 브라우저·IDE 확장과 기존 앱(특히 지갑 앱)의 서명 변화.
2. 2024~2026년 인포스틸러는 대부분 지속성 없이 몇 분 안에 끝납니다(Objective-See 2025). 그래서 15분 스냅샷은 실행되는 순간보다 남은 흔적을 봐야 합니다. 볼 흔적은 숨김 파일, `/tmp`에 모아 둔 데이터, authd·TCC 로그, 다운로드 기록입니다.
3. 기존 규칙 중 오탐이 심한 것이 셋 있습니다. ⑤ "방화벽 꺼짐=높음"(기본값이 꺼짐), ④ "ad-hoc 서명=의심"(Homebrew·Xcode 로컬 빌드), ⑦ ".zshrc 해시 변경"입니다. 또 pluginkit·이벤트 탭처럼 사용자 세션에서만 되는 수집은 데몬만으로는 안 될 수 있습니다.

참고: ATT&CK은 지금 v20.1이고, Defense Evasion이 **Stealth**와 **Defense Impairment** 둘로 나뉘었습니다. 그래서 일부 ID가 예전과 다릅니다(예: Disable or Modify Tools는 T1562.001에서 T1685로 바뀜). 아래 ID는 v20.1 기준입니다.

---

## 2. 추가 항목 표

권한 표기: "사용자 OK"는 이 맥(macOS 27.0.1)에서 sudo 없이 실제로 실행해 본 것입니다. "root 필요"는 실행해 보고 거부된 것, "root"는 실행하지 않고 판단한 것입니다.

### A. 숨은 실행 파일·스테이징·이름 위장 (가장 중요)
| # | 항목 | 왜 위험한지 | 수집 방법 | 1차 규칙 | 우선 | 출처 |
|---|---|---|---|---|---|---|
| A1 | 홈·공용 폴더의 숨김 실행 파일 | AMOS 백도어는 `~/.helper`, `~/.agent`, `~/.pass`(검증된 비밀번호를 평문 저장)를 만듭니다. 같은 유형으로 Zuru의 `/Users/Shared/.fseventsd`, XCSSET의 `~/.zshrc_aliases`가 있습니다. T1564.001 | `~` 바로 아래 dot 파일, `/Users/Shared`, `~/Library/Application Support`, `~/Library/Caches`에서 Mach-O 매직이나 `#!`로 시작하고 실행 비트가 있는 파일을 찾습니다. 서명(`SecStaticCode`), 쿼런틴(`xattr`), hidden 플래그도 확인합니다. root+FDA | 새로 생긴 ad-hoc 또는 무서명 실행 파일, 이름에 pass/pwd가 들어간 숨김 평문 파일 → 높음 | 높음 | Sophos, Moonlock, Objective-See 2024, Microsoft |
| A2 | `/tmp` 계열의 실행 파일·수집 폴더 | AMOS `/tmp/update`·`/tmp/91897/`·`/tmp/out.zip`(`ditto -c -k`로 압축), Banshee `/tmp/<10자>/Browsers·Wallets·Passwords·FileGrabber`, Odyssey `/tmp/pizda/`, PamStealer `/private/tmp/System Settings`, FlexibleFerret `/private/var/tmp/logd`. T1074.001, T1560.001 | `/tmp`, `/private/var/tmp`, 사용자별 `$TMPDIR`의 Mach-O와 zip 목록. zip은 `zipinfo -1`로 경로 이름만 봅니다. root | `/tmp` 아래 Mach-O → 높음. 폴더나 zip 안에 Browsers·Wallets·Keychain·Cookies·Login Data 같은 이름 → 높음 | 높음 | Check Point, Sophos, Objective-See 2025 |
| A3 | Apple 이름 흉내 | ChillyHell `com.apple.qtop`, Zuru `com.apple.fsevents`, PamStealer `~/Library/Application Support/com.apple.finder.core/Finder.app`, NimDoor `GoogIe LLC`(대문자 I), AMOS `com.finder.helper`. T1036.004/.005 | ②의 plist Label과 ④의 프로세스 경로·이름을 그대로 다시 씁니다 | Label이나 번들 ID가 `com.apple.`로 시작하거나 이름이 Finder·System Settings·Software Update인데, Apple 플랫폼 서명이 아니거나 `/System` 밖에 있음 → 높음 | 높음 | Objective-See 2025, Jamf, SentinelOne |

### B. 로그에 남는 권한 상승·피싱 흔적 (① 확장)
| # | 항목 | 왜 위험한지 | 수집 방법 | 1차 규칙 | 우선 | 출처 |
|---|---|---|---|---|---|---|
| B1 | authd 권한 부여 기록 | `osascript ... with administrator privileges`나 가짜 설치 앱이 관리자 비밀번호를 받는 경로입니다. T1548.004 | `log show --predicate 'process == "authd" AND eventMessage CONTAINS "authorizing right"'`. 사용자 OK. 이 맥에서 `Succeeded authorizing right '<right>' by client '<경로>' for authorization created by '<경로>'` 형식이 나오는 것을 확인했습니다 | right가 `system.privilege.admin`이고 client나 created by가 osascript, Script Editor, `/tmp`·숨김 경로, 처음 보는 경로 → 높음. Failed 반복 → 중간 | 높음 | Elastic 규칙, 이 맥에서 실행해 봄 |
| B2 | TCC의 자동화·폴더 접근 요청 주체 | AMOS·Banshee는 osascript로 Finder를 조종해 파일을 복사합니다. Banshee는 실패하면 `tccutil reset AppleEvents`를 최대 30번 실행합니다. T1548.006 | ①의 TCC 로그에서 `kTCCServiceAppleEvents`, `SystemPolicyDocumentsFolder`·`Desktop`·`Downloads`·`AllFiles` 요청 | 요청 주체가 osascript, Script Editor, 처음 보는 바이너리이거나 같은 요청이 짧게 반복됨 → 높음 | 높음 | Check Point, ATT&CK DET0534 |
| B3 | XProtect Remediator 탐지 결과 | Apple이 이미 잡은 악성코드입니다 | `log show --info --last 24h --predicate 'subsystem == "com.apple.XProtectFramework.PluginAPI" AND category == "XPEvent.structured"'`. 스캔이 하루 1번쯤이라 24시간 창이 필요합니다 | 탐지나 치료 기록 1건 이상 → 높음 | 높음 | eclecticlight. 이 맥에서는 최근 3일 결과가 0건이라 형식이 바뀌었는지 **확인 못 함** |
| B4 | syspolicyd "Unsigned code in" | 서명 없는 코드가 실행됐다는 평가 기록입니다 | `log show --info --predicate 'process == "syspolicyd"'` | 개수 급증 → 낮음. 이 맥에서 경로가 해시로 가려져 어떤 파일인지 특정할 수 없었습니다 | 낮음 | 이 맥에서 실행해 봄 |

### C. Apple 보호 기능 상태 (⑤ 확장)
| # | 항목 | 왜 위험한지 | 수집 방법 | 1차 규칙 | 우선 | 출처 |
|---|---|---|---|---|---|---|
| C1 | XProtect 상태·버전 | XProtect가 꺼지거나 업데이트가 멈추면 알려진 악성코드도 통과합니다. Banshee는 XProtect의 문자열 암호화를 베껴 탐지를 피했습니다. T1685 | `xprotect version`(설치 날짜 포함), `xprotect status`(launch/background scans). 사용자 OK, `/usr/bin/xprotect` 있음 | scans disabled → 높음. 설치 날짜가 30일 넘게 지남 → 중간 | 높음 | eclecticlight. `status`·`logs` 서브커맨드가 15.0에도 있는지는 **확인 못 함** |
| C2 | 보안 데이터 자동 업데이트 | ConfigDataInstall(XProtect 데이터)이나 CriticalUpdateInstall이 꺼지면 보안 데이터 업데이트가 막힙니다 | `/Library/Preferences/com.apple.SoftwareUpdate.plist`의 AutomaticCheckEnabled·AutomaticDownload·ConfigDataInstall·CriticalUpdateInstall·AutomaticallyInstallMacOSUpdates, `com.apple.commerce` AutoUpdate. 사용자 OK | ConfigDataInstall·CriticalUpdateInstall이 켜짐→꺼짐 → 높음. 나머지가 꺼짐 → 낮음 | 높음 | mSCP(CIS 매핑) |
| C3 | 부팅 보안 수준·SSV | Reduced나 Permissive면 서드파티 kext를 쓸 수 있고 SIP를 끌 수 있습니다 | `/usr/libexec/mdmclient QuerySecurityInfo`(root 필요 확인)로 SecureBootLevel·AuthenticatedRootVolumeEnabled·RemoteDesktopEnabled를 한 번에 봅니다. `bputil -d`도 root 필요. `csrutil authenticated-root status`는 이 맥처럼 macOS가 여러 개 설치돼 있으면 대화형 질문이 떠서 데몬에서 쓰기 어렵습니다 | SecureBootLevel이 full이 아님, AuthenticatedRoot 꺼짐 → 높음 | 높음 | Apple Platform Security, mSCP |
| C4 | AMFI·라이브러리 검증·NVRAM | boot-args의 `amfi_get_out_of_my_way=1`은 서명 검사를 무력화합니다. DisableLibraryValidation은 dylib 주입을 허용합니다. `apple-trusted-trampoline`은 NVRAM을 쓰는 지속성 기법입니다. T1553.006 | `nvram boot-args`, `nvram -p`(사용자 OK), `/Library/Preferences/com.apple.security.libraryvalidation.plist`(이 맥엔 없음 = 정상) | amfi·cs 관련 boot-args, `rc.trampoline`, `apple-trusted-trampoline`, DisableLibraryValidation=true 중 하나라도 있음 → 높음 | 높음 | mSCP, theevilbit #35 |
| C5 | 커널 확장 | Apple Silicon에서 kext는 Reduced Security여야만 로드됩니다. T1547.006 | `kmutil showloaded --list-only`(사용자 OK) | `com.apple.`이 아닌 kext가 로드됨 → 높음 | 중간 | Apple Platform Security |

### D. 계정·인증
| # | 항목 | 왜 위험한지 | 수집 방법 | 1차 규칙 | 우선 | 출처 |
|---|---|---|---|---|---|---|
| D1 | 계정 추가·숨김 계정·admin 그룹 | T1136.001, T1564.002, T1098.007 | `dscl . -list /Users UniqueID`, `dscl . -read /Users/<u> IsHidden`, `dscl . -read /Groups/admin GroupMembership`, loginwindow plist의 HiddenUsersList·Hide500Users | 새 계정, admin 그룹 새 멤버, IsHidden=1, UID가 500 미만인 비시스템 계정 → 높음 | 높음 | ATT&CK |
| D2 | root·게스트·자동 로그인 | 자동 로그인을 켜면 `/etc/kcpassword`에 비밀번호가 가볍게 가려진 형태로 저장됩니다 | `dscl . -read /Users/root AuthenticationAuthority`, `sysadminctl -guestAccount status`(사용자 OK), loginwindow plist의 autoLoginUser, `/etc/kcpassword` 존재 여부 | root 활성 → 높음. 자동 로그인이나 kcpassword → 중간. 게스트 → 낮음 | 중간 | mSCP |
| D3 | 인증 플러그인 | 로그인 창에서 비밀번호를 가로챌 수 있습니다. KnockKnock 검사 항목입니다 | `/Library/Security/SecurityAgentPlugins`, `security authorizationdb read system.login.console`의 mechanisms | 새 번들이 생기거나 mechanisms가 바뀜 → 높음 | 높음 | KnockKnock, theevilbit #28 |
| D4 | PAM | 바꾸면 모든 인증을 우회할 수 있습니다. T1556.003 | `/etc/pam.d/*` 해시 | 변화가 있고 `pam_permit`·`pam_exec`·서드파티 .so가 추가됨 → 높음. 정상 앱도 파일을 추가하므로 해시 변화만으로는 낮음(이 맥에도 `/etc/pam.d/chrome-remote-desktop`이 있음) | 높음 | theevilbit #05 |

### E. 네트워크 설정·신뢰
| # | 항목 | 왜 위험한지 | 수집 방법 | 1차 규칙 | 우선 | 출처 |
|---|---|---|---|---|---|---|
| E1 | 신뢰 루트 인증서 | MaMi는 System 키체인에 루트 CA를 넣고 DNS를 바꿔 HTTPS를 가로챘습니다. T1553.004 | `security find-certificate -a -Z /Library/Keychains/System.keychain`, `security dump-trust-settings -d`(사용자 OK). 사용자별 trust settings는 사용자 세션에서 봐야 합니다 | 기준값에 없던 신뢰 루트나 신뢰 설정 → 높음 | 높음 | Objective-See MaMi, mSCP |
| E2 | DNS·프록시·PAC | DNS 하이재킹, 애드웨어, 중간자 공격(T1557)에 쓰입니다 | `scutil --dns`, `scutil --proxy`(사용자 OK), `networksetup -getdnsservers / -getautoproxyurl`, `/etc/resolver/*` | 수동 DNS·프록시·PAC가 새로 생기거나 바뀜, `/etc/resolver`에 새 파일 → 높음 | 높음 | MaMi 보도 |
| E3 | 프로세스별 전송량 | 스틸러는 zip을 curl POST로 IP 주소에 직접 보냅니다(AMOS `/contact`, Banshee `/api/send/`). T1041, T1567.004 | `nettop -P -L 1 -J bytes_in,bytes_out`(사용자 OK, root면 전체)을 주기마다 받아 차이를 계산 | 처음 보는 프로세스나 curl·osascript·python의 bytes_out 급증 → 중간 | 중간 | Sophos, Check Point |
| E4 | VPN·pf | | `scutil --nc list`, `/etc/pf.conf`, `/etc/pf.anchors` | 새 구성이 생기거나 바뀜 → 낮음 | 낮음 | |

### F. 공유·원격 서비스 (⑨ 확장)
| # | 항목 | 왜 위험한지 | 수집 방법 | 1차 규칙 | 우선 | 출처 |
|---|---|---|---|---|---|---|
| F1 | 공유 서비스 상태 | 파일 공유, 원격 Apple Events, 인터넷 공유 등은 포트 감시로 놓칩니다 | `launchctl print-disabled system`(사용자 OK)에서 `com.apple.smbd`·`com.apple.screensharing`·`com.openssh.sshd`·`com.apple.AEServer`·`com.apple.tftpd`·`org.apache.httpd`. 추가로 `nfsd status`, `com.apple.nat.plist`, `cupsctl`, `AssetCacheManagerUtil status`, RemoteDesktopEnabled(C3) | 꺼짐→켜짐 → 중간. 원격 로그인·원격 관리·원격 Apple Events는 높음 | 중간 | mSCP |
| F2 | 원격 제어 앱 | AnyDesk·TeamViewer·ScreenConnect·Chrome Remote Desktop은 LISTEN 포트 없이 바깥으로 연결합니다. T1219 | ②·④·⑧ 결과를 알려진 RMM 번들 ID 목록과 매칭 | 새로 설치되거나 실행됨 → 중간 | 중간 | ATT&CK |
| F3 | AirDrop·Bluetooth | | `defaults read com.apple.sharingd DiscoverableMode`(이 맥 값은 `Everyone`), `defaults -currentHost read com.apple.Bluetooth PrefKeyServicesEnabled`, `system_profiler SPBluetoothDataType` | Everyone, Bluetooth 공유 켜짐, 새 페어링 → 낮음 | 낮음 | mSCP |

### G. 확장·플러그인·개발 도구 지속성 (② 확장)
| # | 항목 | 왜 위험한지 | 수집 방법 | 1차 규칙 | 우선 | 출처 |
|---|---|---|---|---|---|---|
| G1 | 브라우저 확장 | T1176.001. 지갑 확장을 노리고(BlueNoroff CryptoBot), 검색 설정을 바꿉니다(JSCoreRunner) | Chrome 계열 `.../<프로필>/Extensions`·`Preferences`·`Secure Preferences`, Firefox `extensions.json`, Safari는 `pluginkit -mAvvv`(사용자 세션 필요) | 웹스토어 출처가 아니거나 `<all_urls>`·`nativeMessaging`·`cookies` 권한 → 높음. 기본 검색엔진 변경 → 중간 | 높음 | KnockKnock, Objective-See 2025 |
| G2 | 브라우저 강제 정책 | 가짜 프로파일로 ExtensionInstallForcelist를 넣어 확장을 강제 설치합니다 | `/Library/Managed Preferences/com.google.Chrome.plist` 등, `profiles status -type enrollment`(사용자 OK) | MDM에 등록되지 않았는데 브라우저 관리 정책이 있음 → 높음 | 높음 | macsecurity.net, Google |
| G3 | IDE 확장·Git hook·Xcode 프로젝트 | Paradox는 Cursor 확장으로 들어왔습니다. XCSSET은 `.git/hooks/pre-commit`과 `.pbxproj`의 `PBXShellScriptBuildPhase`를 씁니다. T1176.002 | `~/.vscode/extensions`, `~/.cursor/extensions`, 홈 아래 저장소의 `.git/hooks/*`(sample 제외), `git config --global core.hooksPath`, 최근 바뀐 `.pbxproj`의 shellScript | 새 확장이나 새 hook, 또는 shellScript에 curl·base64·osascript → 중간(개발자 맥이면 높음) | 중간 | Microsoft XCSSET |
| G4 | Dock·다시 열리는 앱 | XCSSET은 Dock의 Launchpad를 가짜 앱으로 바꿉니다. T1547.007 | `defaults read com.apple.dock persistent-apps`, `~/Library/Preferences/ByHost/com.apple.loginwindow.*.plist` | Dock 항목 경로가 `/Applications`·`/System/Applications` 밖 → 높음 | 중간 | Microsoft, theevilbit #21/#27 |
| G5 | 그 밖의 자동 실행 위치 | login/logout hook(T1037.002), at(T1053.002), StartupItems·rc(T1037.004/.005), DYLD 주입(T1574.006), Python 시작 hook(T1546.018) 등 | LoginHook·LogoutHook(`com.apple.loginwindow`), `/private/var/at/jobs`와 atrun 활성 여부, `/Library/StartupItems`, `/etc/rc.common`·`rc.server`·`rc.netboot`, launchd plist의 `EnvironmentVariables`와 앱 `LSEnvironment`의 `DYLD_*`, `/Library/Spotlight`·`/Library/QuickLook`·`/Library/Screen Savers`·`~/Library/ColorPickers`·`/Library/Audio/Plug-Ins/HAL`·`/Library/PreferencePanes`, `/Library/DirectoryServices/PlugIns`, `pluginkit` 확장, Folder Actions, Terminal·iTerm2 시작 명령, `~/.ssh/rc`, `/etc/ssh/sshrc`, `.pth`·sitecustomize | 새 항목 → 중간. ad-hoc이거나 무서명, 또는 `DYLD_*` 키 존재 → 높음 | 중간 | KnockKnock Plugins, theevilbit |
| G6 | 설치 패키지 | pkg의 postinstall 스크립트로 들어옵니다(HZ RAT, PasivRobber, FlexibleFerret). T1546.016 | `pkgutil --pkgs` 기준값, `/var/log/install.log`, `/Library/Receipts/InstallHistory.plist`(읽기 가능 확인) | 새 패키지와 스크립트 실행 기록 → 중간 | 중간 | Objective-See 2024/2025 |

### H. 다운로드·Gatekeeper 우회 흔적
| # | 항목 | 왜 위험한지 | 수집 방법 | 1차 규칙 | 우선 | 출처 |
|---|---|---|---|---|---|---|
| H1 | 다운로드 기록 DB | 어디서 받았는지 알 수 있고, 쿼런틴 속성을 지워도 기록은 남습니다 | 사용자별 `~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2`(sqlite `LSQuarantineEvent`: AgentName, DataURLString, 시각) | 새 .dmg·.pkg·.app·.scpt·.command·.terminal 파일이 IP 주소나 처음 보는 도메인에서 옴 → 중간. URL 판단은 LLM에 맡기기 좋음 | 중간 | eclecticlight, Binalyze |
| H2 | 쿼런틴 없는 실행 파일 | macOS 15부터 Control-클릭으로 Gatekeeper를 넘기는 방법이 없어져서, "터미널로 끌어다 놓기"나 `xattr -c`를 시키는 수법이 흔해졌습니다(DigitStealer, AMOS `sudo -S xattr -c /tmp/update`). T1553.001 | `/Applications`·`~/Applications`·`~/Downloads`·`/tmp`의 앱과 Mach-O에 `com.apple.quarantine`이 있는지, `spctl -a -vv` 결과 | App Store나 pkg로 설치하지 않았는데 쿼런틴이 없고 공증도 안 됨 → 높음 | 높음 | mjtsai, Objective-See 2025, Sophos |
| H3 | 셸 기록 | ClickFix 흔적이 남습니다: `echo <b64> \| base64 -d \| bash`(AMOS), `curl -kSsfL ... \| zsh`, `osascript -e`, `xattr -c`. T1552.003, T1690 | `~/.zsh_history`, `~/.zsh_sessions/*`, `~/.bash_history`의 새 줄만 | 위 패턴과 일치 → 중간. 기록 파일이 `/dev/null` 링크이거나 갑자기 비워짐 → 중간. 비밀번호가 섞일 수 있으니 일치한 줄만 가려서 LLM에 보냅니다 | 중간 | Sophos, Jamf. Script Editor 경로(`applescript://`)는 셸 기록에 남지 않습니다 |

### I. 앱·파일 무결성
| # | 항목 | 왜 위험한지 | 수집 방법 | 1차 규칙 | 우선 | 출처 |
|---|---|---|---|---|---|---|
| I1 | 기존 앱의 서명·TeamID 변화 | AMOS는 Ledger Live를 가짜 앱으로 바꾸고, DigitStealer는 Ledger Live의 `app.asar`를 변조합니다. T1554 | 앱별 TeamID·CDHash를 기준값으로 두고, 수정 시각이 바뀐 앱만 `codesign --verify --deep --strict` | 서명 깨짐, TeamID 변경, 지갑 앱 변경 → 높음 | 높음 | Objective-See 2025, Moonlock |
| I2 | SUID·SGID | T1548.001 | root로 `find /usr/local /opt /Users /Applications /Library -xdev \( -perm -4000 -o -perm -2000 \)`. 무거우니 하루 1번 | 새 SUID → 높음 | 중간 | ATT&CK |
| I3 | PATH 가로채기 | 가짜 `sudo`로 비밀번호를 빼돌립니다. T1574.007 | `/etc/paths`, `/etc/paths.d/*`, rc 파일의 PATH, PATH 앞쪽 폴더 중 사용자가 쓸 수 있는 곳 | 그런 폴더에 sudo·ssh·git 같은 이름의 파일 → 높음 | 중간 | ATT&CK |

### J. 감시·입력 가로채기
| # | 항목 | 왜 위험한지 | 수집 방법 | 1차 규칙 | 우선 | 출처 |
|---|---|---|---|---|---|---|
| J1 | 키보드 이벤트 탭 | 키로거입니다(BlueNoroff XScreen). T1056.001 | 공개 API `CGGetEventTapList`(ReiKey 방식). 사용자 세션이 필요할 수 있어 앱 쪽에서 실행하는 것이 안전합니다 | Apple 서명이 아닌 프로세스의 키보드 탭 → 높음 | 높음 | ReiKey |
| J2 | 카메라·마이크 사용 | T1123, T1125 | CoreAudio·CoreMediaIO의 `kAudioDevicePropertyDeviceIsRunningSomewhere`(OverSight 방식) | 화면이 잠겼거나 유휴인데 사용 중 → 중간 | 중간 | OverSight 소스 `AVMonitor.m` |
| J3 | 화면 기록 승인 | T1113. NightPaw는 약 5분마다 스크린샷을 찍습니다 | `~/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist`(사용자 권한으로 읽기 실패 → root+FDA) | 새 앱 → 중간 | 중간 | TidBITS |

### K. 상태 점검(낮음)과 자기 보호
| # | 항목 | 수집 방법 | 1차 규칙 | 우선 |
|---|---|---|---|---|
| K1 | 화면 잠금·암호 정책 | `sysadminctl -screenLock status`(사용자 OK, 이 맥은 300초), `pwpolicy getaccountpolicies` | 잠금 꺼짐 → 낮음 | 낮음 |
| K2 | 개발자 모드 | `DevToolsSecurity -status`(사용자 OK) | 꺼짐→켜짐 → 낮음 | 낮음 |
| K3 | Haetae 자기 보호 (출처 없이 제가 제안하는 항목) | `sfltool dumpbtm`의 Haetae 항목 상태, 자기 번들 서명 | 비활성화되거나 변조됨 → 높음 | 중간 |

---

## 3. 기존 9개의 보완점

**① 시스템 로그**
- 빠진 것: authd(B1), XProtect Remediator(B3), sshd 로그인 성공과 원격 IP, screensharingd 인증.
- 한계:
  - 프로세스 실행 기록은 기본 로그에 없습니다. 그래서 osascript 가짜 비밀번호 창 자체는 로그로 못 보고, B1·B2 같은 결과만 봅니다.
  - 값이 `<private>`로 가려지는 경우가 많습니다(syspolicyd 경로가 해시로 나오는 것을 확인).
  - info 레벨은 `--info`를 붙여야 나옵니다.
- `--last 15m`은 잠자기나 지연 때 빈틈이 생깁니다. 마지막 조회 시각부터 읽는 `--start`가 낫습니다.

**② 자동 실행**
- G5 위치들이 빠졌습니다.
- plist 내용 규칙을 추가하는 게 좋습니다. Label이 `com.apple.*`인데 Apple 서명이 아님, ProgramArguments가 bash·osascript·python에 숨김 경로를 넘김, `RunAtLoad`+`KeepAlive`, `StartInterval`.
- NimDoor는 지우면 다시 씁니다. "사라짐→다시 생김"도 기록하세요.

**③ 네트워크**
- 순간 연결은 lsof 스냅샷에 거의 안 잡힙니다. nettop 바이트 차이(E3)를 같이 보세요.
- "처음 보는 LISTEN"은 오탐이 큽니다. ControlCenter(AirPlay 수신 5000/7000), rapportd, 개발 서버 때문에 Apple 플랫폼 서명과 개발 도구 허용 목록이 필요합니다.

**④ 프로세스**
- Apple Silicon에서 arm64 코드는 최소 ad-hoc 서명이 필수라 "서명 없음"은 거의 안 나옵니다(Rosetta x86_64만 해당).
- "ad-hoc=의심"은 Homebrew와 Xcode 로컬 빌드 때문에 오탐이 심합니다. ad-hoc이면서 숨김·`/tmp`·`/Users/Shared`·`Application Support/com.apple.*` 경로이거나 외부 연결이 있을 때만 의심으로 넘기세요.
- 추가할 것:
  - 프로세스 인자와 부모(`ps -axww -o pid,ppid,user,args`). `hidden answer`, `-authonly`, `| sh`, 반복되는 `pbpaste`를 봅니다.
  - `/Volumes`(DMG)에서 실행 중인 프로세스(`hdiutil info`).
  - 실행 파일이 지워진 프로세스.

**⑤ 보안 설정**
- 방화벽은 기본값이 꺼짐이라는 출처가 여럿입니다(Apple 공식 문서로는 확인 못 함). "꺼짐=높음"이면 대부분의 맥에서 계속 울립니다. "켜짐→꺼짐"만 높음으로 하세요.
- `spctl --status`는 사용자가 앱별로 허용한 "Open Anyway" 예외를 보여 주지 않습니다.
- C1~C5를 같이 넣으세요.

**⑥ TCC**
- 꼭 넣을 서비스: Accessibility, ListenEvent, PostEvent, ScreenCapture, AppleEvents(indirect_object 포함), SystemPolicyAllFiles, DeveloperTool.
- MDM으로 준 권한은 `/Library/Application Support/com.apple.TCC/MDMOverrides.plist`에 있습니다.
- macOS 15의 화면 기록 승인은 replayd plist에 있습니다(J3).
- 허용 대상이 ad-hoc 서명이거나 사용자가 쓸 수 있는 경로에 있으면 높음으로 하세요.
- TCC.db 스키마는 버전마다 바뀝니다. 열 이름으로 조회하세요.

**⑦ 시스템 파일**
- 빠진 파일:
  - 셸 설정: `/etc/zshenv`·`zprofile`·`zshrc`·`zlogin`·`zlogout`·`bashrc`·`profile`, 사용자 `.zshenv`·`.zprofile`·`.zlogin`·`.zlogout`·`.bash_profile`·`.bashrc`·`.profile`(ChillyHell은 `.zshrc`·`.bash_profile`·`.profile`을 씁니다).
  - 그 밖: `/etc/ssh/sshd_config(.d)`, `~/.ssh/rc`, `/etc/pam.d/*`, `/etc/paths(.d)`, `/etc/resolver/*`, at 작업.
- `.zshrc`는 brew·conda·nvm이 자주 고칩니다. 해시 변경만으로는 낮음으로 두고, 추가된 줄에 curl·base64·osascript·eval·숨김 파일 source가 있을 때 높음으로 하세요.
- mtime이 아니라 해시 기준을 유지하세요(ChillyHell은 timestomp를 씁니다).
- macOS에서 cron은 기본 비활성이라 새 crontab 자체가 의심입니다.
- `periodic`은 macOS 15에서 제거됐습니다(이 맥에도 `/etc/periodic`이 없음). 감시할 필요가 없습니다.

**⑧ 설치·확장**
- `~/Applications`, 기존 앱의 서명 변화(I1), pkg 영수증(G6), kext(C5)가 빠졌습니다.
- `profiles list`는 root가 아니면 사용자 프로파일만 보입니다. MDM 등록 상태도 기준값에 넣으세요.

**⑨ 원격·USB**
- 3283(ARD)은 UDP도 쓰니 `-iTCP`만으로는 놓칩니다.
- sshd·화면 공유는 launchd가 소켓을 잡고 있어서 LISTEN 주체가 launchd로 나옵니다. 포트로 판단하세요.
- F1 서비스 상태와 F2 원격 제어 앱을 같이 보세요.
- USB는 새 HID(키보드) 장치를 따로 표시하세요. BadUSB일 수 있습니다.

**수집 위치**
- pluginkit, `CGGetEventTapList`, `sysadminctl -screenLock`, `defaults -currentHost`, 사용자 trust settings는 사용자 세션 값입니다. 데몬이 `launchctl asuser`로 돌리거나 앱이 수집해야 합니다.
- 앱이 수집하면 사용자 권한 악성코드가 결과를 조작할 수 있습니다. 둘 중 무엇을 택할지는 정하셔야 합니다.

---

## 4. 제약 때문에 불가능한 항목
- **실시간 실행·파일 감시(BlockBlock 방식)**: Endpoint Security entitlement가 필요합니다. BlockBlock의 entitlement 파일에서 `endpoint-security.client`를 확인했습니다.
- **앱별 아웃바운드 차단(LuLu 방식)**: Network Extension entitlement가 필요하고(LuLu에서 확인), 차단은 2장 Out입니다.
- **DNS 질의 감시(DNSMonitor 방식)**: `NEDNSProxyProvider`, 즉 Network Extension이 필요합니다.
- **키체인·브라우저 비밀번호 파일을 "읽는" 순간 감지**: 파일 열기 이벤트는 ES로만 받을 수 있습니다.
- **클립보드 탈취 감지**: 다른 프로세스의 pasteboard 접근 이벤트가 공개 API에 없습니다.
- **프로세스 인젝션·메모리 상주 코드, 루트킷**: ES나 커널 수준이 필요합니다.
- **펌웨어 변조 검사**: Apple Silicon에서는 정책 상태(C3)만 볼 수 있습니다.
- **두 스냅샷 사이에 끝난 프로세스·연결**: 스냅샷 방식의 한계입니다.
- **예외로 eslogger**: Apple이 서명한 공개 CLI라 entitlement 없이 root와 FDA만으로 ES 이벤트를 JSON으로 받을 수 있습니다(이 맥에 있음). 다만 Apple은 앱이 쓰라고 만든 도구가 아니고 출력이 바뀔 수 있다고 했습니다. 계속 떠 있어야 해서 D6·D15와도 충돌합니다. 쓸지는 정하셔야 합니다.

## 5. 확인 못 함
- `dscl -authonly`로 비밀번호를 검증할 때, 그리고 `tccutil reset` 실행 때 로그에 무엇이 남는지. 직접 테스트하면 실제 인증 실패가 생겨서 하지 않았습니다.
- osascript가 authd 로그에 client로 어떻게 찍히는지. 형식은 확인했지만 osascript 사례는 보지 못했습니다.
- 카메라·마이크 로그(`com.apple.cmio`, `com.apple.coremedia`)가 `log show`로 나중에 조회되는지. OverSight는 실시간 스트림만 씁니다.
- `CGGetEventTapList`가 GUI 세션 없는 root 데몬에서 동작하는지.
- `xprotect status`·`logs`가 macOS 15.0에 있는지, 이 맥(27)에서 XPEvent.structured가 0건인 이유.
- emond가 어느 버전에서 사라졌는지(이 맥엔 없음).
- QuickLook generator 지원이 macOS 15에서 끝났는지.
- AirDrop `Everyone` 값이 10분 뒤 자동으로 돌아가는지.
- `/var/db/SystemPolicyConfiguration/ExecPolicy`(root 전용)에 실행 기록이 있는지.
- Background Security Improvements 설정 키.
- CIS 원문은 가입이 필요해 직접 보지 못했습니다. CIS 항목을 담은 NIST mSCP의 sequoia 규칙으로 대신 확인했습니다.

## 출처
- ATT&CK macOS 매트릭스 v20.1: https://attack.mitre.org/matrices/enterprise/macos/ , DET0534: https://attack.mitre.org/detectionstrategies/DET0534
- KnockKnock 플러그인 목록: https://github.com/objective-see/KnockKnock/tree/main/Plugins , theevilbit Beyond: https://theevilbit.github.io/beyond/
- Objective-See Mac Malware 2025: https://objective-see.org/blog/blog_0x84.html , 2024: https://objective-see.org/blog/blog_0x7D.html , ReiKey: https://objective-see.org/products/reikey.html , OverSight: https://github.com/objective-see/OverSight , MaMi: https://objective-see.org/blog/blog_0x26.html
- Check Point Banshee: https://research.checkpoint.com/2025/banshee-macos-stealer-that-stole-code-from-macos-xprotect/
- Moonlock AMOS 백도어: https://moonlock.com/amos-backdoor-persistent-access , Sophos AMOS: https://www.sophos.com/en-us/blog/why-amos-matters-the-macos-malware-stealing-data-at-scale
- Microsoft XCSSET: https://www.microsoft.com/en-us/security/blog/2025/03/11/new-xcsset-malware-adds-new-obfuscation-persistence-techniques-to-infect-xcode-projects/
- SentinelOne NimDoor: https://www.sentinelone.com/labs/macos-nimdoor/ , Cuckoo: https://thehackernews.com/2024/05/new-cuckoo-persistent-macos-spyware.html
- Jamf PamStealer: https://www.jamf.com/blog/pamstealer-macos-infostealer-applescript-rust/ , Jamf ClickFix(Script Editor): https://www.jamf.com/blog/clickfix-macos-script-editor-atomic-stealer/
- NIST mSCP(CIS 매핑): https://github.com/usnistgov/macos_security/tree/sequoia/rules , CIS: https://www.cisecurity.org/benchmark/apple_os
- Apple Platform Security(시동 보안): https://support.apple.com/guide/security/sec7d92dc49f/web
- XProtect(Sequoia): https://eclecticlight.co/2024/09/25/how-xprotect-has-changed-in-macos-sequoia/ , XPR 로그: https://eclecticlight.co/2022/09/01/hunting-malware-protection-in-the-log/ , periodic 제거: https://eclecticlight.co/2024/11/06/sequoia-catches-periodic-and-vms/
- Gatekeeper Control-클릭 제거: https://mjtsai.com/blog/2024/07/05/sequoia-removes-gatekeeper-contextual-menu-override
- QuarantineEventsV2: https://kb.binalyze.com/air/features/acquisition/supported-evidence/macos-collections-detail/quarantine-events
- Chrome 강제 정책 악용: https://macsecurity.net/view/492-extensioninstallforcelist-chrome-policy-mac
- 화면 기록 승인 plist: https://tidbits.com/2024/09/23/how-to-avoid-sequoias-repetitive-screen-recording-permissions-prompts/
- eslogger: https://keith.github.io/xcode-man-pages/eslogger.1.html , https://developer.apple.com/videos/play/wwdc2022/110345/
- osascript 관리자 권한 규칙: https://www.elastic.co/guide/en/security/current/apple-scripting-execution-with-administrator-privileges.html

---
파일은 수정하지 않았고 sudo도 쓰지 않았습니다. root가 필요한 명령의 실제 출력은 보지 못했습니다. 셸 기록이나 다운로드 URL을 LLM에 보내는 규칙(H1·H3)은 개인정보가 넘어갈 수 있으니, 가림 방식을 먼저 정해야 합니다.
