# 다음 세션 시작 프롬프트

> 새 세션에서 아래 코드 블록 내용을 그대로 붙여 넣는다. 갱신: 2026-11-21 (WO-8 재리뷰 3까지 반영)

```
Haetae 프로젝트 이어서 작업해줘. 작업 디렉터리: 이 저장소 루트

## 먼저 읽을 것 (전부 읽지 말고 이 순서로)
1. docs/haetae-security-monitor.md — 단일 진실 소스(SSOT, 약 250KB). 처음부터 끝까지 읽지 말고 `rg -n`으로 찾아서:
   - 맨 위 헤더(상태·다음 액션), 0장(문서 규칙), 8장(주의사항)
   - 지금 할 WO(6장 "### WO-N")와 그 WO가 가리키는 3-3 결정(D#), XPC 관련이면 3-7
   - 필요할 때만 1-1(요구사항 R1~R19), 3-1·3-2(다이어그램), 3-5(감시 대상), 7장(검증), 9장(Q1~Q40)
2. 참고 자료는 필요할 때만: docs/research/ (extra-security-checks.md, llm-candidates.md, security-threat-review.md, dev-tools.md)

## 현재 상태 (2026-11-21)
- 문서 상태 `구현중`. WO-1~8 `[x]`, WO-9~46 `[ ]`.
  - Phase 1(WO-1~7): 패키지 연결, `HaetaeShared` XPC 계약, 앱 번들 구성, 데몬 뼈대, 앱 뼈대, 단위 테스트 43개, XPC 거부 확인 도구(`Tools/xpc-probe/`).
  - Phase 2: WO-8 `CommandRunner`(`HaetaeKit/Sources/HaetaeChecks/Engine/CommandRunner.swift`)까지. 리뷰 2개(보안, 설계·동시성)와 재리뷰 3번을 반영했다(마지막: 실행 파일은 링크 없이 닿는 시스템 볼륨의 파일만, 정리는 항상 `killpg`부터). 단위 테스트는 WO-19에서 쓴다.
- Phase 1 검증: 7-1은 별도 에이전트가 끝냈다(구현 결함 0건). 남은 것은 사용자 확인뿐이다.
  - 7-2 R16(XPC 거부 결과를 받아들이는지) — 사용자 답 대기
  - 로그아웃 뒤 자동 실행(7-2 R2·R12, 7-1 P1 "등록 흐름"의 로그아웃 항목) — 사용자가 로그아웃했다고 하면 그 시각의 데몬 로그에 `markUserQuit`이 있는지 본다
  - "끄면 다음 로그인 때 안 뜬다"는 사용자 결정으로 건너뜀. "검증 실패 표시"는 Phase 6로 옮김.
  - 사용자 지시로 이 확인들을 남긴 채 Phase 2를 시작했다.
- 미정인 결정: Q40(`launchctl asuser`가 uid를 바꾸지 않음 — WO-26 전에 사용자에게 번호로 묻는다). 지금 작업은 막지 않는다.
- 이 맥: `/Applications/Haetae.app`에 개발용 Debug 사본이 root 소유로 설치돼 있고 데몬·에이전트가 등록·승인돼 있다. 앱이 켜져 있을 수 있다(`pgrep -lx Haetae`). 데몬 쪽 코드를 바꾼 뒤 실제 동작을 보려면 사용자가 8장의 sudo 복사 명령을 다시 실행해야 한다.
- 서명: 두 타깃 Apple Development, Personal Team 47XT7DPDLP. hardened runtime 켜짐.
- 도구: swift-lsp 플러그인 + buildServer.json, codegraph 인덱스(.codegraph/), Peekaboo MCP, 스킬 write-swift·swift-testing-expert·swiftui-expert-skill·swift-concurrency·paseo-handoff·reviewer.
- git: main이 origin/main에 push돼 있다(public 저장소). 커밋 이메일은 저장소 로컬 설정(개인 이메일)이라 바꾸지 않는다.

## 작업 규칙 (사용자 지시)
- 답변은 한국어 존댓말로 쉽고 짧게, 결론 먼저. 코드에 있는 이름은 번역하지 않는다. 확실하지 않으면 그렇다고 쓴다. 질문은 번호 선택지를 일반 텍스트로(선택지 UI 도구 금지).
- Swift 코드를 쓰기 전에 write-swift·swift-concurrency(UI면 swiftui-expert-skill) 스킬을 읽고 Swift 6.4 방식으로 쓴다(8장 "Swift 작성 기준").
- 1회 1WO. 집을 때 `[~]`, 끝나면 `[x]`와 완료 판정 결과. 세션을 마칠 때 헤더·WO 상태·10장 작업 로그·이 문서를 갱신한다.
- 테스트 WO(WO-19, 25, 35, 42)는 직접 쓰지 말고 paseo-handoff로 별도 에이전트에게 넘긴다. 7-1 검증도 구현하지 않은 별도 에이전트가 실제로 실행한다.
- WO마다 코드 리뷰: 구현이 끝나면 별도 에이전트 여럿에게 관점을 나눠 맡긴다(보안 / 설계·동시성·확장성, 수정 금지). 지적은 구현 쪽이 설계 원칙·보안을 지키며 고치고, 고친 것은 재리뷰를 받는다. 설계 변경이 필요한 지적은 9장에 올려 묻는다.
  - 에이전트: Paseo `create_agent`, provider `claude/claude-opus-5-5`, `settings: {modeId: "auto", thinkingOptionId: "xhigh"}`. `create_agent`는 다른 도구 호출과 한 번에 보내지 않는다. 결과는 그대로 믿지 말고 핵심 근거를 직접 확인한다.
- 커밋·push는 사용자가 지시할 때만 한다(지금까지 WO마다 "커밋 푸시 해"로 지시해 왔다). 제목은 `type: 요약`(feat·fix·docs·build·chore·test), 성격이 다르면 나누고 Phase·WO 번호는 본문에. AI 서명(Co-Authored-By) 금지. 커밋과 push는 따로 실행한다.
- 커밋 전 개인정보 확인(public 저장소): 7-1 공통 "개인정보" 항목의 `rg` 명령 2개(계정 이름은 대소문자 구분, 나머지는 `-i`) → 둘 다 0곳. `rg`가 rtk에 감싸여 실패하면 exit 1이 나와 "결과 없음"과 같으니 stderr를 꼭 본다. 회사 정보·실명·로컬 절대 경로를 저장소에 넣지 않는다.
- 3-3 결정(D1~D32)·2장 Out에서 벗어나는 것, 사용자 판단이 필요한 것은 임의로 정하지 말고 9장에 올린 뒤 번호 선택지로 묻는다.
- 빌드 설정(Debug/Release, 배포 타깃, 팀)은 WO에 적힌 것 외에는 바꾸지 않는다.
- 에이전트가 못 하는 것: sudo(사용자에게 터미널 명령을 주고 실행을 부탁), `sfltool dumpbtm`(인증 창에서 멈춤 — 실행 금지), 메뉴 막대 아이콘 클릭(패널 확인은 사용자에게 부탁, 화면이 잠겨 있으면 화면 도구가 아예 안 된다). `log show`는 `rtk proxy log show …`로 실행한다.

## 다음 할 일
WO-9(`SafeFileReader`·`UserDirectory`)부터 시작한다. `CommandRunner`를 쓸 때 주의할 점은 8장에 있다(허용 경로와 링크 거부, `--`, 성공 판정, 최대 시간). 사용자가 R16이나 로그아웃 결과를 알려 주면 7-2에 기입한다.
```
