# 다음 세션 시작 프롬프트

> 새 세션에서 아래 코드 블록 내용을 그대로 붙여 넣는다. 작성: 2026-11-19

```
Haetae 프로젝트 이어서 작업해줘. 작업 디렉터리: 이 저장소 루트

## 먼저 읽을 것 (전부 읽지 말고 이 순서로)
1. docs/haetae-security-monitor.md — 단일 진실 소스(SSOT, 약 140KB). 처음부터 끝까지 읽지 말고:
   - 맨 위 헤더(상태·다음 액션), 0장(문서 규칙), 8장(주의사항)
   - 지금 할 WO(6장 "### WO-N")와 그 WO가 가리키는 3-3 결정(D#), XPC 관련이면 3-7
   - 필요할 때만 1-1(요구사항 R1~R19), 3-1·3-2(다이어그램), 3-5(감시 대상), 7장(검증)
2. 참고 자료는 필요할 때만: docs/research/ (extra-security-checks.md, llm-candidates.md, security-threat-review.md, dev-tools.md)

## 현재 상태 (2026-11-20)
- 기획·설계·작업 계획 끝, 사용자 승인됨. 문서 상태 `구현중`. WO-1~7 `[x]`(Phase 1 구현·테스트 전부: 패키지 연결, `HaetaeShared` XPC 계약, 앱 번들 구성, 데몬 뼈대, 앱 뼈대, 단위 테스트 43개, XPC 거부 확인 도구), WO-8~46 `[ ]`. Phase 1의 7-1·7-2 검증은 아직이다. 이 맥의 `/Applications/Haetae.app`에 개발용 Debug 사본이 root 소유로 설치돼 있고 데몬·에이전트가 등록돼 있다(실제 등록·연결·종료 흐름은 2026-11-20 확인, 로그아웃만 미확인).
- 서명: 두 타깃 Apple Development, Personal Team 47XT7DPDLP로 빌드 확인됨. hardened runtime은 WO-3에서 켰다.
- 도구: swift-lsp 플러그인 + buildServer.json(xcode-build-server), codegraph 인덱스(.codegraph/), Peekaboo MCP(손쉬운 사용 권한을 Paseo.app에 줘야 함 — 안 돼 있으면 사용자에게 요청), 스킬 write-swift·swift-testing-expert·swiftui-expert-skill·swift-concurrency 플러그인·macos-security-bypass(탐지 규칙 참고용만)·find-skills. 사용자 스킬 xcode-build-verify, reviewer, paseo-handoff 사용 가능.
- git: main이 origin/main에 push돼 있다(public 저장소). 커밋 이메일은 저장소 로컬 설정(개인 이메일)이라 바꾸지 않는다.

## 작업 규칙 (사용자 지시)
- Swift 코드를 쓰기 전에 write-swift·swift-concurrency·swiftui-expert-skill 스킬을 읽고, Swift 6.4 최신 방식으로 쓴다(8장 "Swift 작성 기준").
- 1회 1WO. 집을 때 상태를 [~]로 바꾸고, 끝나면 [x]와 완료 판정 결과를 적는다. 세션을 마칠 때 헤더·WO 상태·10장 작업 로그를 갱신한다(0장 규칙 8).
- 테스트 WO(WO-6, 7, 19, 25, 35, 42)는 직접 쓰지 말고 paseo-handoff로 별도 에이전트에게 넘긴다. 프롬프트에 문서 경로와 WO 번호를 넣는다.
- 7-1 검증도 구현하지 않은 별도 에이전트가 실제로 실행한다.
- WO마다 코드 리뷰: 구현이 끝나면 paseo-handoff로 별도 에이전트에게 리뷰만 맡긴다(수정 금지, 기준 ~/.claude/skills/reviewer/SKILL.md, 설계 원칙·보안 필수). 지적은 구현 쪽이 설계 원칙·보안을 지키며 고친 뒤 다음 WO로 넘어간다. 설계 변경 지적은 9장에 올려 묻는다.
- 커밋은 Phase 완료(7-1 통과 + 7-2 사용자 확인) 뒤에 한다. 제목은 `type: 요약`(feat·fix·docs·build·chore·test 등), 성격이 다르면 type별로 나누고 Phase·WO 번호는 본문에 적는다. AI 서명(Co-Authored-By) 금지. push는 사용자가 지시할 때만.
- 3-3 결정(D1~D32)·2장 Out에서 벗어나는 것, 사용자 판단이 필요한 것은 임의로 정하지 말고 9장에 올린 뒤 번호 선택지로 묻는다.
- 빌드 설정(Debug/Release, 배포 타깃, 팀)은 WO에 적힌 것 외에는 바꾸지 않는다.

## 다음 할 일
Phase 1의 7-1 검증부터 시작해(구현하지 않은 별도 에이전트가 실행 — paseo-handoff. 등록된 데몬이 필요한 항목은 사용자에게 8장의 sudo 복사 명령을 요청하고, XPC 거부 항목은 `Tools/xpc-probe/run-probes.sh`로 본다). 통과하면 7-2를 사용자에게 확인받고 Phase 2(WO-8)로 넘어간다.
```
