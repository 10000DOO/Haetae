# 다음 세션 시작 프롬프트

> 새 세션에서 아래 코드 블록 내용을 그대로 붙여 넣는다. 갱신: 2026-11-26 (WO-12 완료 시점)

```
Haetae 프로젝트 이어서 작업해줘. 작업 디렉터리: 이 저장소 루트

## 맨 먼저
`git fetch` 후 `git log main..origin/main`을 본다. 다른 세션이 먼저 push했으면 pull(fast-forward)한 뒤 이 문서를 다시 읽는다(2026-11-23에 로컬이 3커밋 뒤처져 낡은 문서로 시작한 적이 있다).

## 먼저 읽을 것 (전부 읽지 말고 이 순서로)
1. docs/haetae-security-monitor.md — 단일 진실 소스(SSOT, 약 380KB). 처음부터 끝까지 읽지 말고 `rg -n`으로 찾아서:
   - 맨 위 헤더(상태·다음 액션), 0장(문서 규칙), 8장(주의사항)
   - 지금 할 WO(6장 "### WO-N")와 그 WO가 가리키는 3-3 결정(D#), XPC 관련이면 3-7
   - 필요할 때만 1-1(요구사항 R1~R19), 3-1·3-2(다이어그램), 3-5(감시 대상), 7장(검증), 9장(Q1~Q68)
2. 참고 자료는 필요할 때만: docs/research/ (extra-security-checks.md, llm-candidates.md, security-threat-review.md, dev-tools.md)

## 현재 상태 (2026-11-26)
- 문서 상태 `구현중`. WO-1~12·WO-47~52 `[x]`, WO-13~46 `[ ]`.
  - Phase 1(WO-1~7): 패키지 연결, `HaetaeShared` XPC 계약, 앱 번들 구성, 데몬 뼈대, 앱 뼈대, 단위 테스트 43개, XPC 거부 확인 도구(`Tools/xpc-probe/`).
  - Phase 2에서 끝난 것(모두 별도 에이전트 리뷰 반영, 단위 테스트는 WO-19):
    - WO-8 `CommandRunner` — 셸 없이 SIP 경로의 시스템 볼륨 파일만 실행. stdin 입력과 "자기 실행 파일(cdhash 요구사항)" 허용은 해석 서비스가 쓴다.
    - WO-9 `SafeFileReader`·`UserDirectory` — 사용자 파일은 그 사용자 권한으로 열기, 시스템 파일은 root 전용 폴더 규칙, 전용 스레드·취소·상한. sudo로 root 경로 확인함.
    - WO-10 `Fingerprint`·`SecureDirectory`·`BaselineStore`·`FindingLedger`(`HaetaeChecks/Store/`) — 사용자별 기준값·원장, pending 상한, 알림 완료 사본.
    - WO-47~50 사용자 파일 해석 분리 — 새 타깃 `haetae-parser`(해석 서비스: 별도 서명 정체, launchd가 nobody로 띄움, 파일마다 자기를 `--parse`로 띄워 그 자식이 해석, 유휴 30초 종료). 데몬은 `IsolatedParser`(XPC 클라이언트)로 맡기고 결과만 검증한다. `haetaed --parse`는 없앴다. 구조와 실측은 6장 WO-49·50, 주의사항은 8장 "해석 서비스"·"`IsolatedParser`" 항목.
    - WO-51·52 — 앱이 해석 서비스도 등록(`ServiceRegistrar`). 실측에서 해석 서비스가 데몬의 전체 디스크 접근을 그대로 받는 것이 드러나(TCC는 같은 앱 번들로 본다) 해석 자식이 입력 전에 전부 막는 샌드박스에 들어가게 했다(`ParserProcess.enterSandbox`, Q56 1번 — 문서에 없는 `sandbox_init` 호출이라 OS가 막으면 자식이 77로 끝나고 서비스가 `unavailable`로 답한다). 실측과 남는 위험은 6장 WO-51·52, 8장 "해석 자식".
    - WO-11 `SecurityCheck`·`CheckRunner`·`SecretMasker`·`PatternStore`(`HaetaeChecks/Engine/`) — 검사 엔진. 별도 에이전트 리뷰 2개를 6차 재리뷰까지 반영해 커졌다(설계는 6장 WO-11의 "리뷰 반영"·"2차"~"7차 반영"). WO-12가 쓸 때 꼭 알 것: ack 뒤 기준값 확정은 `CheckRunner.confirmAfterAck(uid:)`로만, 30일 정리는 `CheckRunner.purge(olderThan:)`로만(`FindingLedger.purge`·`BaselineStore.confirmPending`을 직접 부르지 않는다 — 실행과 겹치는 틈), `runAll`은 사용자마다 줄을 세워 다른 uid는 온 순서대로 돈다. 검사를 쓸 때 지킬 것은 8장 "검사를 쓸 때(WO-11)"(`partial`, 첫 실행, 200건 상한·시간 예산으로 다음 실행에 미룸, 검사 id 형식, 수집과 판정 나누기).
    - WO-12 `CollectCoordinator`·`DaemonLifecycleState`·`SelfIntegrityCheck`(`HaetaeChecks/Engine/`), `SelfIdentity`·`BundleIntegrity`(`HaetaeShared` — 앱·데몬·해석 서비스 공용), 데몬 `DaemonConfiguration`·`ListenerDelegate`·`CollectService` — XPC 4개 메서드 완성. 판단은 패키지(테스트 가능, Q23), 데몬 타깃은 어댑터·타이머·`exit`만. WO-13이 쓸 때 꼭 알 것: 앱은 `collect`마다 ack한다(새 건이 없으면 빈 목록 — 데몬은 ack로만 검사 공백 표시를 지움, Q67), `CollectResult.notified`가 nil이면 "이번엔 안 보냄"(가진 패널 유지), `HaetaeXPCError.rateLimited`(20초 안 재요청)·`updating`(옛 데몬, 연결을 놓고 다시)은 `DaemonClient`가 처리한다, `AppState.connect()`가 지금 `collect` 결과의 `scanGap`·`resolved`를 버리니 파이프라인으로 넘긴다. 설계·리뷰 경과는 6장 WO-12.
- Phase 1 검증: 7-1은 별도 에이전트가 끝냈다(구현 결함 0건). 남은 것은 사용자 확인뿐이다.
  - 7-2 R16(XPC 거부 결과를 받아들이는지) — 사용자 답 대기
  - 로그아웃 뒤 자동 실행(7-2 R2·R12, 7-1 P1 "등록 흐름"의 로그아웃 항목) — 사용자가 로그아웃했다고 하면 그 시각의 데몬 로그에 `markUserQuit`이 있는지 본다
  - "끄면 다음 로그인 때 안 뜬다"는 사용자 결정으로 건너뜀. "검증 실패 표시"는 Phase 6로 옮김.
  - 사용자 지시로 이 확인들을 남긴 채 Phase 2를 진행 중이다.
- 정해진 결정(9장 Q41~Q68, 본문 반영 끝): 앱 `collect` 대기는 검사 상한 × 2 + 5초(Q63), ack한 위험 요약은 `collect` 응답에(Q64), 30일 정리는 데몬이 뜬 뒤 첫 `collect` 전·하루마다(Q65), 검증 실패 연결은 1분에 한 줄로 묶음(Q66 — 비정상 종료도 같게), 검사 공백은 ack로만 지움(Q67), `highest-build`를 못 읽으면 그 실행만 fail-open(Q68), 일부만 본(`partial`)·사용자를 모르는 실행은 `since`를 묶고 기준값은 첫 실행이면 확정(Q57·Q62), 실패·`partial`·시간 미룸은 최근 5번 중 3번이면 한 단계 올림(Q58·Q62), 취소에 안 응하는 검사는 기다리고 WO-19에서 시험(Q59), `SecretMasker`의 과잉 가림은 WO-16에서(Q60), 가린 흔적이 있으면 LLM이 수준을 못 낮춤(Q61, WO-22), 해석 자식은 샌드박스에(Q56), 사용자 파일도 링크 수를 보지 않음(Q46), 해석은 별도 프로그램으로(Q42·Q48 2번·Q54 1번), 기준값은 사용자별(Q50), 위험 항목은 기준값에 넣지 않음(Q51), pending이 넘치면 낮은 수준의 새 것부터 버림(Q52), 알림 완료 사본을 데몬이 보관해 다시 보냄(Q53), pending 기준값 장치는 유지(Q55).
- 미정인 결정 (지금 작업은 막지 않는다):
  - Q49(launchd가 바꿔치기된 데몬·해석 서비스를 띄우는 경우 — `SpawnConstraint`) — WO-45 전.
  - Q45(`/private/var/at/jobs`가 daemon 소유) — WO-16 전.
  - Q40(`launchctl asuser`가 uid를 바꾸지 않음) — WO-26 전.
- 이 맥: `/Applications/Haetae.app`에 개발용 Debug 사본이 root 소유로 설치돼 있고 데몬·에이전트가 등록·승인돼 있다(2026-11-24 WO-52 빌드 — 해석 서비스까지 등록됨, 전체 디스크 접근 목록에 Haetae가 켜져 있다). 앱이 켜져 있을 수 있다(`pgrep -lx Haetae`). 데몬 쪽 코드를 바꾼 뒤 실제 동작을 보려면 사용자가 8장의 sudo 복사 명령을 다시 실행해야 한다.
- 서명: 세 타깃(`Haetae`·`haetaed`·`haetae-parser`) Apple Development, Personal Team 47XT7DPDLP. hardened runtime 켜짐.
- 도구: swift-lsp 플러그인 + buildServer.json, codegraph 인덱스(.codegraph/), Peekaboo MCP, 스킬 write-swift·swift-testing-expert·swiftui-expert-skill·swift-concurrency·paseo-handoff·reviewer. Paseo 데몬이 꺼져 있으면 `paseo daemon start --home ~/.paseo`. MCP 도구가 없으면 CLI로: `paseo run --no-wait -q --provider claude/claude-opus-5-5 --mode auto --thinking xhigh --cwd <저장소> "$(cat 프롬프트)"`, 이어 보내기 `paseo send --no-wait --prompt-file <파일> <id>`(닫힌 에이전트도 맥락 유지), 기다리기 `paseo wait <id>`(백그라운드), 결과 `paseo logs <id>`.
- git: main이 origin/main에 push돼 있다(public 저장소). 커밋 이메일은 저장소 로컬 설정(개인 이메일)이라 바꾸지 않는다.

## 작업 규칙 (사용자 지시)
- 답변은 한국어 존댓말로 쉽고 짧게, 결론 먼저. 코드에 있는 이름은 번역하지 않는다. 확실하지 않으면 그렇다고 쓴다. 질문은 번호 선택지를 일반 텍스트로(선택지 UI 도구 금지).
- Swift 코드를 쓰기 전에 write-swift·swift-concurrency(UI면 swiftui-expert-skill) 스킬을 읽고 Swift 6.4 방식으로 쓴다(8장 "Swift 작성 기준").
- 1회 1WO. 집을 때 `[~]`, 끝나면 `[x]`와 완료 판정 결과. 세션을 마칠 때 헤더·WO 상태·10장 작업 로그·이 문서를 갱신한다.
- 테스트 WO(WO-19, 25, 35, 42)는 직접 쓰지 말고 paseo-handoff로 별도 에이전트에게 넘긴다. 7-1 검증도 구현하지 않은 별도 에이전트가 실제로 실행한다.
- WO마다 코드 리뷰: 구현이 끝나면 별도 에이전트 여럿에게 관점을 나눠 맡긴다(보안 / 설계·동시성·확장성, 수정 금지). 지적은 구현 쪽이 설계 원칙·보안을 지키며 고치고, 고친 것은 재리뷰를 받는다. 설계 변경이 필요한 지적은 9장에 올려 묻는다.
  - 에이전트: Paseo `create_agent`, provider `claude/claude-opus-5-5`, `settings: {modeId: "auto", thinkingOptionId: "xhigh"}`. `create_agent`는 다른 도구 호출과 한 번에 보내지 않는다. 결과는 그대로 믿지 말고 핵심 근거를 직접 확인한다.
- 커밋·push는 사용자가 지시할 때만 한다(2026-11-23 세션에서는 "리뷰에서 문제 없으면 커밋 푸시 하고 다음 작업으로 이어가"라는 지시로 WO마다 커밋·push했다 — 새 세션에서는 다시 확인한다). 제목은 `type: 요약`(feat·fix·docs·build·chore·test), 성격이 다르면 나누고 Phase·WO 번호는 본문에. AI 서명(Co-Authored-By) 금지. 커밋과 push는 따로 실행한다.
- 커밋 전 개인정보 확인(public 저장소): 7-1 공통 "개인정보" 항목의 `rg` 명령 2개(계정 이름은 대소문자 구분, 나머지는 `-i`) → 둘 다 0곳. `rg`가 rtk에 감싸여 실패하면 exit 1이 나와 "결과 없음"과 같으니 stderr를 꼭 본다. 회사 정보·실명·로컬 절대 경로를 저장소에 넣지 않는다.
- 3-3 결정(D1~D32)·2장 Out에서 벗어나는 것, 사용자 판단이 필요한 것은 임의로 정하지 말고 9장에 올린 뒤 번호 선택지로 묻는다.
- 빌드 설정(Debug/Release, 배포 타깃, 팀)은 WO에 적힌 것 외에는 바꾸지 않는다.
- 저장소 밖 임시 테스트(SwiftPM 패키지가 `HaetaeKit`을 경로로 의존, `@testable import HaetaeChecks`)로 실측할 때, 시간 예산을 쓰는 `CheckRunner` 테스트는 `swift test --no-parallel`로 돌린다(병렬이면 CPU를 나눠 다음 실행으로 미루는 일이 생긴다 — 정상 동작). 개수를 보는 테스트는 `CheckRunner(maskBudget:maxRunDuration:)`을 넉넉히 준다.
- sudo 없이 launchd 동작을 시험할 때는 사용자 도메인 임시 작업을 쓴다(`launchctl bootstrap gui/$(id -u) <plist>` → 시험 → `launchctl bootout`, 끝나면 반드시 지운다 — 8장). 시험 파일은 저장소 밖(`/private/tmp`)에 만들고 지운다.
- 에이전트가 못 하는 것: sudo(사용자에게 터미널 명령을 주고 실행을 부탁), `sfltool dumpbtm`(인증 창에서 멈춤 — 실행 금지), 메뉴 막대 아이콘 클릭(패널 확인은 사용자에게 부탁, 화면이 잠겨 있으면 화면 도구가 아예 안 된다). `log show`는 `rtk proxy log show …`로 실행한다.

## 다음 할 일
1. WO-13(앱 파이프라인 `HaetaeAppCore`). 시작 전에 6장 WO-13의 "WO-12에서 넘어온 것"을 읽는다: `collect`마다 ack(빈 목록 포함, Q67), `notified` nil 처리, `connect()`가 버리는 `scanGap`·`resolved`.
2. 그다음 WO-15~18(검사), WO-19(테스트 — 별도 에이전트, WO-11·12 임시 테스트 시나리오는 WO-19 6-1·8-1번). Phase 2를 닫을 때 7-1 P2는 실제 데몬(root 소유 사본, Q33)으로 별도 에이전트가 확인한다 — WO-12의 종료 순서·새 빌드 종료·자기 무결성·업데이트 흐름은 코드 읽기와 패키지 시험까지만 확인됐다.
`CommandRunner`·`SafeFileReader`·`UserDirectory`·`IsolatedParser`·저장소·`CheckRunner`·`CollectCoordinator`를 쓸 때 주의할 점은 8장과 6장 WO-11·12에 있다(`/private/…` 경로, `UserRecord.root`와 `.rootOnly`, 검사 안에서 병렬로 읽지 않기, `UserRecord` 직접 만들지 않기, `parse`는 한 번에 하나씩, 해석 자식 안에서는 파일·로캘이 필요한 API 금지, `unavailable`은 검사 실패 1건·`failed`는 파일별 Finding, "검사를 쓸 때(WO-11)", ack 확정·정리는 `CollectCoordinator`가 `CheckRunner`로만 등). 사용자가 R16이나 로그아웃 결과를 알려 주면 7-2에 기입한다(R16은 "7-1 XPC 거부 결과를 받아들이는지", 로그아웃은 그 시각 데몬 로그의 `markUserQuit` 확인).
```
