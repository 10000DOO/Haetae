# 개발 도구 조사 (플러그인·스킬·MCP·CLI)

> 작성: 2026-11-19, Claude 서브에이전트 조사 결과 원문 · 상위 문서: [../haetae-security-monitor.md](../haetae-security-monitor.md)
> 이 파일의 설치 명령은 참고용이다. 설치 여부는 상위 문서 9장 Q20에서 사용자가 정한다.
> Claude 직접 확인(2026-11-19): `xcrun --find mcpbridge` 있음, `xcode-build-server` 설치됨, 공식 마켓플레이스에 `xcode` 플러그인 항목 있음, `~/.claude.json`의 swift-lsp·clangd MCP가 `--transport stdio` 인자로 등록돼 있음, MobileBuildMCP·Peekaboo·Swift Concurrency 스킬 저장소 존재(archived 아님).

---

# Haetae 구현에 쓸 Claude Code 도구 조사 결과

## 1. 결론

- **꼭 쓸 것 (1):** Apple 공식 `xcode@claude-plugins-official` 플러그인과 `MobileBuildMCP`입니다. `MobileBuildMCP`는 XcodeBuildMCP가 2.7.1에서 이름을 바꾼 것이며, `macos`와 `swift-package` 워크플로만 켜서 씁니다. 빌드, 실행, 테스트, `swift test`를 맡습니다.
- **꼭 쓸 것 (2):** 이미 설치된 `swift-lsp` 플러그인은 동작합니다. 다만 다른 파일로 이동하려면 `xcode-build-server`로 `buildServer.json`을 만들어야 합니다. 연결에 실패한 `swift-lsp`·`clangd` MCP 항목은 잘못 등록된 것이라 지우면 됩니다.
- **문서와 배포:** 지금 있는 `context7`(Sparkle, mlx-swift-lm 둘 다 찾아짐)와 `apple-docs`로 충분합니다. 서명, 공증, pkg는 Xcode 내장 CLI와 Sparkle `bin/` 도구로 충분해서 따로 스킬을 깔 필요가 없습니다.
- **있으면 좋은 것:** Peekaboo(메뉴바 아이콘 목록·클릭·화면 캡처), AvdLee의 Swift Concurrency 스킬, `xcsift`, `SwiftLint`.
- **주의:** 이 맥 키체인에 유효한 코드 서명 인증서가 0개입니다(`security find-identity -v -p codesigning`). 서명, 공증, XPC 서명 검증 단계 전에 준비해야 합니다.

## 2. 도구 표

신뢰도의 별 수와 날짜는 `gh api`로 확인한 값입니다. 날짜는 최근 릴리스 날짜이고, 릴리스가 없으면 최근 push 날짜입니다.

| 이름 | 종류 | 쓰는 단계 | 이 맥 상태 | 설치 방법 | 신뢰도 | 출처 |
|---|---|---|---|---|---|---|
| `xcode` 플러그인 (Apple) | plugin. MCP(`xcrun mcpbridge`)와 스킬 포함 | 빌드, 테스트, 빌드 로그, SwiftUI 프리뷰, Apple 문서 검색 | 미설치. 마켓플레이스 항목은 로컬에 있음. `xcrun mcp-server status`: Permission enabled, 서버 not running | `claude plugin install xcode@claude-plugins-official`<br>MCP만 쓸 때: `claude mcp add --transport stdio xcode -- xcrun mcpbridge`<br>Xcode 없이 쓰려면 `sudo xcrun mcp-server enable` | Apple 공식. 버전이 Xcode를 따라가고 커밋 고정 없음 | [Apple 문서](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode), [플러그인 분석 글](https://blakecrosley.com/blog/xcode-plugin-claude-code) |
| MobileBuildMCP (구 XcodeBuildMCP) | MCP와 CLI | 앱 빌드·실행·종료(`build_run_macos`, `launch_mac_app`, `stop_mac_app`), `test_macos`, HaetaeKit `swift_package_test`, 커버리지 | 미설치 | `claude mcp add MobileBuildMCP -e MOBILEBUILDMCP_SENTRY_DISABLED=true -e MOBILEBUILDMCP_ENABLED_WORKFLOWS=macos,swift-package -- npx -y mobilebuildmcp@latest mcp` | 6.6k★, v2.7.1 (2026-09-23), Sentry | [GitHub](https://github.com/getsentry/MobileBuildMCP), [인수 공지](https://blog.sentry.io/sentry-acquires-xcodebuildmcp) |
| `swift-lsp` | plugin(LSP) | 정의 이동, 타입 확인 | 설치됨, 동작함(hover, documentSymbol 성공) | 이미 있음 | Anthropic 공식 마켓 47.7k★ | [GitHub](https://github.com/anthropics/claude-plugins-official) |
| `xcode-build-server` | CLI | `.xcodeproj`에서 swift-lsp가 파일 간 탐색을 하게 함 | 1.3.0 설치됨(최신) | 한 번 빌드한 뒤 `xcode-build-server config -project Haetae.xcodeproj -scheme Haetae` 실행. 저장소에 `buildServer.json`이 생김 | 1.0k★, v1.3.0 (2026-01-05), 개인(SolaWing) | [GitHub](https://github.com/SolaWing/xcode-build-server) |
| `context7` | MCP | Sparkle, mlx-swift-lm 문서 | 설치됨, 동작함 | 이미 있음 | 65k★, Upstash | [GitHub](https://github.com/upstash/context7) |
| `apple-docs` | MCP | Apple API 문서 | 설치됨, 동작함 | 이미 있음 | 1.4k★, npm 1.0.26 (2025-09-15), 개인 | [GitHub](https://github.com/kimsungwhee/apple-docs-mcp) |
| Xcode 내장 CLI | CLI | 빌드, 공증, pkg | `xcodebuild` 27.0, `swift` 6.4, `notarytool` 1.1.3, `pkgbuild`·`productbuild`(`/usr/bin`) 있음 | 없음 | Apple | - |
| Sparkle `generate_keys` / `sign_update` / `generate_appcast` | CLI | EdDSA 키 만들기, 업데이트·appcast 서명 | 없음(패키지 추가 전) | SPM으로 추가하면 `SourcePackages/artifacts/sparkle/Sparkle/bin/`에 생김 | 9.9k★, 2.10.1 (2026-10-25), sparkle-project | [문서](https://sparkle-project.org/documentation/) |
| `codegraph` | CLI와 MCP | 앱·데몬·HaetaeKit 사이 호출 경로 탐색 | CLI 1.6.0, MCP 등록됨, 인덱스 없음 | `codegraph init`(사용자가 결정), `codegraph upgrade`(최신 1.6.3) | 78k★, v1.6.3 (2026-11-17), 개인 | [GitHub](https://github.com/colbymchenry/codegraph) |
| `gh` | CLI | 릴리스, appcast 호스팅 | 2.100.0 있음 | 없음 | GitHub | - |
| Peekaboo | MCP와 CLI | 메뉴바 아이콘 목록·클릭(`menubar list/click`), 메뉴바·화면 캡처 | 미설치 | `brew install openclaw/tap/peekaboo`<br>`claude mcp add peekaboo -- npx -y @steipete/peekaboo mcp`<br>화면 기록, 손쉬운 사용 권한 필요 | 5.5k★, v4.9.9 (2026-11-16), openclaw(원작자 steipete) | [GitHub](https://github.com/openclaw/Peekaboo) |
| Swift Concurrency 스킬 (AvdLee) | skill/plugin | XPC, actor, Sendable 코드 | 미설치 | `/plugin marketplace add AvdLee/Swift-Concurrency-Agent-Skill` 후 설치 | 1.7k★, push 2026-11-06, 개인 | [GitHub](https://github.com/AvdLee/Swift-Concurrency-Agent-Skill) |
| SwiftUI 스킬 (아래 둘 중 하나만) | skill | `MenuBarExtra`, `Settings` UI | 미설치 | AvdLee: `npx skills@latest add https://github.com/avdlee/swiftui-agent-skill --skill swiftui-expert-skill`<br>twostraws: `npx skills add https://github.com/twostraws/swiftui-agent-skill --skill swiftui-pro` | AvdLee 3.9k★, 5.3.0 (2026-11-06)<br>twostraws 6.6k★, 2.0.0 (2026-10-09) | [AvdLee](https://github.com/AvdLee/SwiftUI-Agent-Skill), [twostraws](https://github.com/twostraws/SwiftUI-Agent-Skill) |
| `xcsift` | CLI | `xcodebuild` 출력을 JSON/TOON으로 짧게 요약 | 미설치 | `brew install xcsift` | 520★, v1.7.5 (2026-11-11), 개인 | [GitHub](https://github.com/ldomaradzki/xcsift) |
| `SwiftLint` | CLI | lint | 미설치 | `brew install swiftlint` | 19.8k★, 0.65.1 (2026-08-21), realm | [GitHub](https://github.com/realm/SwiftLint) |
| `swift-format` | CLI | 포맷 | Xcode 내장(`xcrun swift-format`, `swift format`) 있음 | 이미 있음 | 3.0k★, 604.0.0 (2026-09-16), swiftlang | [GitHub](https://github.com/swiftlang/swift-format) |
| sosumi.ai | MCP(HTTP) | `apple-docs`의 대안 | 미설치 | `claude mcp add --transport http sosumi https://sosumi.ai/mcp` | 492★, push 2026-11-13, NSHipster | [GitHub](https://github.com/NSHipster/sosumi.ai) |

표에 덧붙일 점:
- **Xcode 플러그인:** 스킬 설명이 세션마다 약 4.5k 토큰을 씁니다(분석 글 기준). `swiftui-specialist`, `modernize-tests`, `audit-xcode-security-settings` 같은 스킬이 들어 있습니다.
- **MobileBuildMCP:** 기본값으로 Sentry에 오류 정보를 보내서 위 명령에 끄는 설정을 넣었습니다. `ui-automation` 워크플로는 iOS 시뮬레이터 전용이라 macOS UI는 조작하지 못합니다(manifest에서 확인).
- **사람이 할 일:** `SMAppService.daemon` 등록 승인과 pkg 설치(관리자 암호)는 어떤 MCP도 대신 못 합니다. 사람이 해야 합니다.
- **codegraph를 쓰면 좋은 점:** Swift를 지원합니다. `codegraph_explore` 한 번으로 심볼 소스와 호출 경로가 함께 나옵니다. XPC 프로토콜 구현체처럼 grep으로 따라가기 어려운 연결도 찾아줍니다. MCP가 이미 등록돼 있어서 `init`만 하면 재시작 없이 바로 쓸 수 있습니다. 지금은 파일이 몇 개뿐이라 효과는 코드가 커질수록 커집니다.

## 3. 이 맥에 있는데 안 되는 것

**`swift-lsp`, `clangd` MCP 연결 실패**
- **원인:** `~/.claude.json`의 `mcpServers`에 LSP 서버가 MCP 서버로 잘못 등록돼 있습니다. 두 가지가 겹쳐 있습니다.
  1. `swift-lsp`는 `xcrun sourcekit-lsp --transport stdio`, `clangd`는 `/opt/homebrew/opt/llvm/bin/clangd --transport stdio`로 실행됩니다. 직접 돌려 보니 두 프로그램 모두 `--transport` 옵션을 모른다며 바로 종료했습니다. 그래서 `CONNECTION_CLOSED`가 납니다.
  2. 옵션을 빼도 안 됩니다. LSP와 MCP는 서로 다른 프로토콜입니다.
- **고치는 방법:** 두 항목을 지우면 됩니다. LSP 기능은 이미 켜진 `swift-lsp@claude-plugins-official`, `clangd-lsp@claude-plugins-official` 플러그인이 제공합니다. 이번 세션에서 `LSP` 도구로 hover가 실제로 동작했습니다.
  ```
  claude mcp remove swift-lsp -s user
  claude mcp remove clangd -s user
  ```

**swift-lsp에서 다른 파일로 이동이 안 됨**
- `HaetaeApp.swift`의 `ContentView()`에서 `goToDefinition`을 실행하면 "No definition found"가 나옵니다. sourcekit-lsp가 `.xcodeproj`를 직접 읽지 못하기 때문입니다.
- 위 표의 `xcode-build-server config`로 `buildServer.json`을 만들면 됩니다. HaetaeKit은 SwiftPM 패키지라 이 설정 없이도 됩니다.

**PATH의 `swift-format`**
- PATH 앞쪽의 다른 `swift-format`(Chromium `depot_tools` 래퍼)가 먼저 잡혀서, Chromium 폴더 밖에서는 실패합니다.
- `xcrun swift-format`이나 `swift format`을 쓰면 됩니다.

**codegraph MCP**
- 1.6.0으로 돌고 있고 최신은 1.6.3입니다(`codegraph upgrade`).

## 4. 추천하지 않는 것

- `xcodebuildmcp` 이전 이름의 패키지와 Homebrew 탭: 2.7.1에서 `mobilebuildmcp`로 이름이 바뀌었습니다.
- `steipete/macos-automator-mcp`: 저장소가 archived 상태입니다.
- Axiom(`CharlesWiltgen/Axiom`): 스킬 289개, 에이전트 44개에 hook까지 있어 무겁습니다. Xcode 플러그인과 사용자 스킬(`developer`, `reviewer`)과도 겹칩니다.
- `Dimillian/Skills`의 `macos-spm-app-packaging`: `.xcodeproj`가 없는 SwiftPM 전용 앱용이고 Codex 중심입니다.
- `jamesrochabrun/skills`의 `releasing-macos-apps`: DMG 중심이고 이 프로젝트는 pkg를 씁니다. 마지막 push가 2026-01입니다.
- `rcodesign`(apple-platform-rs): 마지막 릴리스가 2024-11이고, 맥에서는 내장 도구로 충분합니다.
- `swift-package-readme-mcp-server`(elchika-inc): `context7`과 겹칩니다.
- 함께 쓰면 중복인 조합: AvdLee와 twostraws의 SwiftUI 스킬, `SwiftFormat`(nicklockwood)과 `swift-format`, `xcbeautify`와 `xcsift`. 각각 하나만 씁니다.
- 사용자 스킬 `mac-local-build`: 다른 팀 전용이고 pbxproj를 고칩니다. Haetae에는 맞지 않습니다.

## 5. 확인 못 함

- 이 맥 Xcode 27.0에서 `xcode` 플러그인에 들어 있는 스킬 목록과 MCP 도구 수: 확인 못 함. 분석 글은 Xcode 27.2 기준으로 스킬 16개, 도구 54개라고 합니다. 목록을 보려면 `export`로 파일을 써야 해서 실행하지 않았습니다.
- Peekaboo가 알림 배너를 확인할 수 있는지: 확인 못 함. 문서에는 메뉴바 목록·클릭·캡처만 나옵니다.
- `rorkai/app-store-connect-cli-skills`(asc-notarization, 1.1k★)의 pkg 공증 내용: 확인 못 함. 검색 결과 요약만 봤습니다.
- 서명 인증서가 0개인 상태에서 Automatic signing으로 `xcodebuild`가 되는지: 확인 못 함. 빌드는 돌리지 않았습니다.

아무것도 설치하거나 설정을 바꾸지 않았습니다. README를 읽으려고 `/tmp`에 임시 파일(`mbm_readme.md`, `pb_*.md`)만 만들었습니다. 웹 정보 중 Xcode 플러그인 관련 내용은 Apple 문서가 아니라 블로그 글(2026-11-11) 기준이라, 설치 뒤 실제 내용과 다를 수 있습니다.

---

## 추가: find-skills 검색 결과 (2026-11-19, Claude 직접 실행)

- 도구: `vercel-labs/skills`의 `find-skills` 스킬 설치(`npx -y skills@1.9.0 add vercel-labs/skills -s find-skills -g -a claude-code -y`, 텔레메트리 끔 환경 변수), 검색은 `npx -y skills@1.9.0 find "<검색어>"`
- 검색어: swift, swiftui, macos, xpc, code signing, notarization, launchd, security audit, xcode, unit test swift, swift testing, menu bar, sparkle, swift package, macos security, swift concurrency

| 스킬 | 설치 수 | 저장소 | 판단 |
|---|---|---|---|
| `emilkowalski/skills@write-swift` | 171.7K | ★58k, 2026-11-15 | 추천. Swift 6 데이터 경합 안전성, approachable concurrency(main-actor-by-default — 이 프로젝트 설정과 같음), 값 타입·프로토콜·API 설계, Swift Testing |
| `avdlee/swift-testing-agent-skill@swift-testing-expert` | 5.6K | ★482, 2026-09-14 | 추천(테스트 핸드오프 에이전트용). `#expect`/`#require`, 매개변수 테스트, async 대기, XCTest 이전 |
| `twostraws/swift-testing-agent-skill@swift-testing-pro` | 10.9K | ★483, 2026-05-17 | 위와 겹침, 하나만 |
| `twostraws/swiftui-agent-skill@swiftui-pro` / `avdlee/swiftui-agent-skill@swiftui-expert-skill` | 38.6K / 36.9K | | 선택. 이 앱 UI는 작음 |
| `yaklang/hack-skills@macos-security-bypass` | 3.8K | ★2.7k | 설치 비추천(공격 기법 모음, 스킬은 에이전트 권한으로 실행됨). Phase 4 규칙 설계 때 참고 자료로만 읽기 |
| `rorkai/app-store-connect-cli-skills@asc-notarization`, `openai/plugins@packaging-notarization` | 7K / 85 | | Phase 6에서 다시 검토 |
| xpc, launchd, sparkle, menu bar(SwiftUI 일반 제외), swift package | - | | 이 프로젝트에 맞는 스킬 없음 |

### 설치 결과 (2026-11-19)
- 설치(global, claude-code): `find-skills`, `write-swift`, `swift-testing-expert`, `swiftui-expert-skill`(AvdLee, SwiftUI는 하나만 — 두 스킬이 겹쳐 서로 다른 방식을 권할 수 있음), `macos-security-bypass`(마크다운 2개, 탐지 규칙 설계 참고용으로만 사용)
- `swiftui-expert-skill`의 `scripts/`는 Instruments 트레이스 기록·분석 Python이며 네트워크·셸 실행 패턴(curl, sudo, eval 등) 없음을 확인
- 설치 안 함: `asc-notarization` — 서드파티 `asc` CLI와 App Store Connect API 키로 공증함(이 프로젝트는 Apple `notarytool` 사용, D22·WO-44). `packaging-notarization` — 47줄 일반 안내로 notarytool·pkg 내용 없음
