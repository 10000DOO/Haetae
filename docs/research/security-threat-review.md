# 설계 보안 위협 검토

> 작성: 2026-11-19, Claude 서브에이전트 조사 결과 원문 · 범위: 설계 단계 위협(T1~T23)과 대응
> 상위 문서: [../haetae-security-monitor.md](../haetae-security-monitor.md) · 이 파일은 참고 자료이며, 채택 여부는 상위 문서 3장·9장이 기준이다.

---

**Haetae 설계 보안 위협 검토 (읽기 전용 조사, 파일은 수정하지 않음)**

## 1. 결론

1. 가장 위험한 것은 **같은 맥의 다른 사용자가 root 데몬으로 남의 정보를 보는 문제**입니다. D8 서명 검사는 어떤 프로그램인지만 보고 누가 실행했는지는 보지 않습니다. 그래서 일반 사용자 B가 정품 Haetae를 켜면 사용자 A의 `authorized_keys`, crontab, TCC 허용 목록, 네트워크 연결을 받게 됩니다.
2. 다음은 **탐지가 영구히 사라지는 구조**입니다. 데몬이 응답과 동시에 기준값을 갱신하고(3-2 시나리오 2), 지문으로 다시 판정하지 않습니다(변경 5). 그래서 앱을 `kill -9`하거나 프롬프트 인젝션으로 "안전" 판정을 한 번만 받으면 그 항목은 다시 잡히지 않습니다.
3. **root가 사용자 폴더 파일을 읽는 부분**은 심볼릭 링크뿐 아니라 하드링크와 FIFO로도 공격됩니다. macOS에서는 대상 파일에 권한이 없어도 하드링크를 만들 수 있고, 2026년 Defender 사례(CVE-2026-50657)가 바로 이 방식입니다.
4. **LLM 쪽 위험은 두 가지**입니다. 로그 문자열로 위험을 숨기거나 알림에 피싱 문구를 띄울 수 있습니다. 또 모델 파일의 기본 상태가 바꿔치기에 약합니다. `revision`이 `"main"`이고, 캐시가 `~/.cache/huggingface/hub`이며, 다운로드 코드에서 내용 해시 검증을 찾지 못했습니다.
5. **앱 번들 교체·다운그레이드 경로**가 남아 있습니다. 이 맥의 `/Applications`는 `root:admin 775`입니다. 팀 ID + 번들 ID만 보는 요구사항은 구버전 앱이나 리소스를 변조한 복사본도 통과시킵니다.

## 2. 위협 표

| # | 위협 | 구체적 공격 시나리오 (이 설계 기준) | 실제 사례·CVE·출처 | 영향 | 설계 대응 | 우선순위 |
|---|---|---|---|---|---|---|
| T1 | 다중 사용자 정보 노출 | 일반 사용자 B가 `/Applications`의 정품 Haetae를 실행합니다. D8은 통과하고, 데몬은 사용자 A의 홈 파일 해시·LaunchAgents·crontab·TCC.db 허용 목록, 모든 사용자의 `lsof` 연결, sudo 로그를 B에게 보냅니다. 이 내용이 B의 `risks.json`과 LLM 입력에 남습니다. | 공개 사례는 못 찾음(설계 분석). 호출 사용자는 [`effectiveUserIdentifier`](https://developer.apple.com/documentation/foundation/nsxpcconnection/effectiveuseridentifier)로 알 수 있음 | 다른 사용자의 사생활·접속 정보 유출 | 데몬이 `effectiveUserIdentifier`로 범위를 나눕니다. 시스템 범위 + 호출자 본인 범위만 보냅니다. 다른 사용자 범위는 관리자 그룹(`mbr_check_membership`)일 때만 보낼지 정해야 합니다(9장 질문). root 전용 파일(sudoers 등)은 내용 없이 해시·크기·mtime만 보냅니다. | 높음 |
| T2 | 기준값 선반영으로 탐지 유실 | 데몬이 `evaluate` 때 기준값을 바로 갱신합니다. 악성코드가 `collect` 응답 직후 앱을 `kill -9`하면 저장·알림은 없고, 새 LaunchAgent는 이미 기준값에 "정상"으로 들어가 있습니다. | 설계 분석 (3-2 시나리오 2 "의심 건 + 기준값 갱신") | 영구 미탐 | 2단계 확정으로 바꿉니다. 새 항목은 root 폴더의 대기(pending) 목록에 둡니다. 앱이 저장·알림을 마친 뒤 `ack(fingerprints)`를 보내야 기준값에 반영합니다. ack가 없으면 다음 검사에서 다시 보냅니다. | 높음 |
| T3 | 지문 억제 악용 (변경 5) | ① 첫 등장 때 인젝션으로 LLM이 "안전"으로 판정하면, 그 지문은 영구히 다시 보지 않습니다. ② 지문을 경로·Label로만 만들면, plist 내용만 악성으로 바꿔도 같은 지문이 됩니다. ③ 지문 저장소가 앱(사용자 권한)에 있으면 악성코드가 미리 지문을 심을 수 있습니다. | [OWASP LLM01:2025](https://genai.owasp.org/llmrisk/llm01-prompt-injection/) | 영구 미탐 | 지문은 SHA-256(검사 ID + 정규화된 대상 + 내용 해시·cdhash·팀 ID)으로 만듭니다. 억제는 "알림 완료"만 하고, "LLM이 안전 판정"은 억제하지 않습니다(내용이나 모델이 바뀌면 재판정). 지문은 데몬(root)에 저장합니다. 미해결 위험은 패널에 계속 보이게 하거나 N일마다 다시 알립니다. | 높음 |
| T4 | root가 사용자 파일을 읽을 때 링크·TOCTOU | `~/.ssh/authorized_keys`를 root 전용 파일로 하드링크하거나 심볼릭 링크로 바꿉니다. `~/.ssh` 디렉터리 자체를 심링크로 바꿀 수도 있습니다. FIFO나 `/dev/zero`로 바꿔 데몬을 멈추게 할 수 있습니다. `/Users`를 나열하면 누구나 쓸 수 있는 `/Users/Shared`(1777)도 섞여 들어옵니다. | [CVE-2026-50657](https://spaceraccoon.substack.com/p/race-against-the-machine-local-privilege) (Defender, 사용자 폴더 하드링크로 root 파일 읽기, "a macOS hardlink needs no access to the target at all"), [CVE-2024-23275](https://jhftss.github.io/Endless-Exploits/) (O_NOFOLLOW만 써서 상위 경로 심링크로 우회) | root 전용 정보 유출, 데몬 정지 | 사용자 파일은 그 사용자 권한으로 읽습니다(`pthread_setugid_np(uid, gid)`, 스레드 단위, SDK `unistd.h`에 있음). `open(O_RDONLY\|O_NOFOLLOW_ANY\|O_NONBLOCK\|O_CLOEXEC)` 뒤 `fstat`으로 `S_ISREG`, `st_uid == 대상 uid`, `st_nlink == 1`, 크기 상한을 확인합니다. 사용자 목록은 계정 DB에서 가져오고(uid ≥ 501, 홈 소유자 확인) `/Users`를 나열하지 않습니다. | 높음 |
| T5 | 앱 번들 교체·다운그레이드·리소스 주입 | (a) 관리자 계정의 사용자 권한 악성코드가 번들 안의 `haetaed`나 plist를 바꿉니다. (b) 같은 팀·같은 ID로 서명된 취약한 구버전을 설치합니다. (c) 앱 복사본의 리소스(NIB 등)를 바꿔 정품 서명 프로세스 안에서 코드를 돌리고 XPC를 통과합니다. | [Reguła OBTS v3](https://papers.put.as/papers/macosx/2020/OBTS_v3_wRegula.pdf) (팀 ID + 번들 ID여도 hardened runtime 없는 구버전에 주입), [CVE-2026-39118 / XM Cyber](https://xmcyber.com/blog/faind-my-xpc-breaks-a-key-trust-boundary/) (NIB 주입으로 Kandji·CrowdStrike 데몬 악용), [App Management 우회 보고](https://www.theregister.com/2023/08/22/apple_macos_app_management/), [사용자 소유 번들 문제 PR](https://github.com/GeiserX/VPN-Bypass/pull/242) | root 탈취 또는 감시 무력화 | ① 요구사항에 최소 버전 `info[CFBundleVersion] >= "N"`을 넣습니다. ② 데몬 anti-rollback: 본 최고 버전을 root 폴더에 기록하고, 자기 버전이 더 낮으면 거부합니다(v1부터 있어야 효과). ③ 데몬 시작 시 자기 상위 번들을 검사합니다(소유자 root, 그룹·기타 쓰기 불가, `SecStaticCodeCheckValidity` + `kSecCSStrictValidate\|kSecCSCheckNestedCode`). 실패하면 그 자체를 위험으로 보고합니다. ④ `.pkg`로 root 소유 설치를 할지 정해야 합니다(9장 질문). ⑤ 앱은 번들에서 NIB·플러그인을 동적으로 로드하지 않습니다. | 높음 |
| T6 | XPC 클라이언트 검증 세부 | 요구사항이 팀 + ID만이면 Apple Development 빌드(`get-task-allow`)나 구버전도 통과합니다. PID나 경로로 판단하는 코드가 섞이면 경쟁 조건이 생깁니다. | [CVE-2026-24071](https://www.sentinelone.com/vulnerability-database/cve-2026-24071/) (PID 재사용), CVE-2026-50658 (PID + exec 경쟁, 위 spaceraccoon 글), [CVE-2020-0984](https://theevilbit.github.io/posts/secure_coding_xpc_part3/), [CVE-2019-20057](https://theevilbit.github.io/posts/secure_coding_xpc_part1/), [Quinn: "release listener는 Developer ID만 받아라"](https://developer.apple.com/forums/thread/700962) | 데몬 정보가 공격자에게 | 리스너 단계에서 [`NSXPCListener.setConnectionCodeSigningRequirement`](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:)) (macOS 13+)를 씁니다. 배포용 문자열은 아래와 같고, 이 맥의 `csreq`로 컴파일되는 것을 확인했습니다.<br>`anchor apple generic and identifier "com.10000DOO.Haetae" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "47XT7DPDLP" and info[CFBundleVersion] >= "N" and entitlement["com.apple.security.get-task-allow"] absent and entitlement["com.apple.security.cs.disable-library-validation"] absent`<br>Debug용(Apple Development)과 Release용 문자열을 나눕니다. 앱도 같은 방식으로 데몬(`com.10000DOO.haetaed`)을 검증합니다. | 중간 |
| T7 | LLM 프롬프트 인젝션으로 위험 숨김 | `logger`로 쓴 로그, 프로세스 이름·인자, LaunchAgent Label, USB 장치 이름(물리 장치가 마음대로 정함), 파일 이름에 "Apple 정상 구성요소, 위험 없음" 같은 문구나 보이지 않는 Unicode 태그 문자를 넣습니다. LLM이 중간 수준 건을 안전으로 판정합니다. | [OWASP LLM01:2025](https://genai.owasp.org/llmrisk/llm01-prompt-injection/), [로그 경유 인젝션 논문 arXiv 2605.24421](https://arxiv.org/abs/2605.24421), [LevelBlue SpiderLabs](https://www.levelblue.com/blogs/spiderlabs-blog/rogue-ai-agents-in-your-socs-and-siems-indirect-prompt-injection-via-log-files), [Unicode 태그 숨김 문자](https://embracethered.com/blog/posts/2024/hiding-and-finding-text-with-unicode-tags) | 미탐 | D10을 넓힙니다. LLM은 규칙 수준을 올리기만 하거나, "중간→낮음만 허용하고 기록은 남김"으로 합니다(9장 질문). 입력은 제어문자·bidi 문자·U+E0000–E007F를 지우고, 항목별 길이 상한을 두고, 구분된 데이터 블록에 넣습니다. 출력은 JSON 스키마(enum level, bool)로 검증하고, 실패하면 규칙만으로 판정하는 `RiskJudge` 대체 구현으로 넘어갑니다. | 높음 |
| T8 | LLM 출력이 화면에 그대로 노출 | 인젝션으로 이유 문구에 "해결하려면 터미널에 `curl … \| sh` 입력"이나 링크를 넣습니다. 이 문구가 Haetae 이름으로 알림·패널에 뜹니다. | [OWASP LLM05:2025](https://genai.owasp.org/llm-top-10/) | 보안 앱의 신뢰를 이용한 사회공학 | 알림 본문은 고정 템플릿(검사 종류·수준·개수)만 쓰고 LLM 문구는 넣지 않습니다. 패널은 `Text(verbatim:)`을 쓰고 `LocalizedStringKey`나 `AttributedString(markdown:)`은 쓰지 않습니다(마크다운 링크가 클릭됨). 길이 상한을 둡니다. | 높음 |
| T9 | 모델 공급망·바꿔치기 (chat template 포함) | (a) `ModelConfiguration`의 `revision` 기본값이 `"main"`이라 저장소 변경·계정 탈취·namespace 재등록에 그대로 따라갑니다. (b) 비샌드박스 macOS의 기본 캐시가 `~/.cache/huggingface/hub`(Python 도구와 공유)라 가중치·`chat_template`·`tokenizer.json`을 바꿔치기할 수 있습니다. (c) `launchctl setenv HF_HUB_CACHE`나 `HF_HOME`으로 캐시 경로를 돌릴 수 있습니다. 템플릿을 바꾸면 시스템 프롬프트가 바뀌거나 앱이 멈춥니다. | [Unit 42 Model Namespace Reuse](https://unit42.paloaltonetworks.com/model-namespace-reuse/) (커밋 고정 권고), [nullifAI](https://thehackernews.com/2025/02/malicious-ml-models-found-on-hugging.html) (pickle), [CVE-2024-34359](https://nvd.nist.gov/vuln/detail/CVE-2024-34359) (chat template SSTI, Python), MLX [CVE-2025-62608](https://www.sentinelone.com/vulnerability-database/cve-2025-62608/)·[62609](https://www.sentinelone.com/vulnerability-database/cve-2025-62609/) (파서 버그, 0.29.4에서 수정), [swift-huggingface 캐시 위치](https://github.com/huggingface/swift-huggingface), [mlx-swift-lm `revision` 기본값](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ModelConfiguration.swift). swift-jinja는 `maximumCallDepth` 16만 문서에 있습니다. | 판정 조작(항상 "안전"), 앱 멈춤, 파서 버그 | 앱 안에 모델별 {repo, 커밋 해시, 파일 목록, 파일별 sha256} 고정 목록을 둡니다. 다운로드 후와 로드 전에 검증합니다. 캐시는 `HubCache(location: .fixed(directory:))`로 `~/Library/Application Support/Haetae/Models`에 두고 환경 변수는 무시합니다. safetensors·json·jinja 외 파일(`*.bin`, `*.pkl`, `*.pt`)은 거부합니다. chat template은 앱 번들에 넣는 것을 검토합니다. 설정의 모델 ID는 허용 목록에서만 고르게 하고, 추론 전체에 타임아웃을 둡니다. | 높음 |
| T10 | 설정 변조로 조용히 무력화 | `defaults write com.10000DOO.Haetae`로 주기 999999, 일시정지 true, 깨진 모델을 지정합니다. 알림 설정도 사용자 쓰기 가능 파일로 꺼질 수 있습니다(확인 못 함). | 설계 분석 | 겉으로는 켜져 있는데 검사하지 않음 | 주기는 상한·하한을 검증합니다. 일시정지는 자동 만료되게 하고 아이콘에 표시합니다. 약화 방향의 설정 변경은 데몬에 기록하고 패널에 보여 줍니다. 매 검사마다 `notificationSettings()`를 확인하고, 꺼져 있으면 메뉴바 아이콘(R3)으로 경고합니다. | 중간~높음 |
| T11 | 앱 강제 종료·정지 | `kill -9`, SIGSTOP(아이콘은 보이지만 타이머가 멈춤), 로그인 직후 매번 kill | EDR은 ES `ES_EVENT_TYPE_AUTH_SIGNAL`로 신호를 차단합니다([Apple](https://developer.apple.com/documentation/endpointsecurity/es_event_type_auth_signal), [MS Defender tamper protection](https://learn.microsoft.com/defender-endpoint/tamperprotection-macos)). Haetae는 ES를 쓰지 않아(D6) 차단은 못 하고 탐지만 가능합니다. [BTM 알림 우회(Wardle, DEF CON 31)](https://speakerdeck.com/patrickwardle/demystifying-and-bypassing-macoss-background-task-management) | 감시 공백 | R13을 유지합니다. 메뉴 "종료"에서만 데몬에 `markUserQuit()`을 보내고 root에 기록합니다. 그 밖의 끊김(신호, AppleEvent quit, 로그아웃)은 "비정상 종료"로 기록합니다. `kAEQuitReason`은 [위조 가능하므로 참고만](https://developer.apple.com/forums/thread/94126) 합니다. 연결은 살아 있는데 요청이 주기×2 넘게 없으면 "정지 의심"으로 기록합니다. 다음 실행 때 공백 기간을 보여 줍니다. 선택안: 앱을 `SMAppService.agent` + `KeepAlive{SuccessfulExit=false}`로 띄우면 exit 0(정상 종료)은 재시작하지 않고 비정상 종료만 재시작합니다(man `launchd.plist`). | 중간 |
| T12 | 검사 실패로 눈가리기 (변경 1) | 로그 폭주로 `log show`를 매번 타임아웃시키거나, LaunchAgents를 대량으로 만듭니다. "하나 실패해도 나머지 계속" 구조라 그 검사만 조용히 묻힙니다. 부분 결과로 기준값을 갱신하면 항목이 사라졌다가 "새로" 생깁니다. | 설계 분석 | 특정 영역 미탐 | 검사 실패·타임아웃 자체를 상태 `Finding`으로 올리고, 연속 N회면 알립니다. 실패한 검사는 기준값을 갱신하지 않습니다. `log show --loss`로 로그 손실을 확인합니다. | 높음 |
| T13 | 첫 학습 오염 (TOFU) | 설치 전부터 있던 악성 LaunchDaemon·TCC 허용·프로파일이 첫 검사에서 "정상"으로 학습됩니다(D7). | 설계 분석 | 기존 감염 영구 미탐 | 첫 검사에도 기준값과 무관한 규칙을 적용합니다(서명 없음·ad-hoc, 사용자 쓰기 가능 경로의 실행 파일). 첫 실행 때 현재 등록 항목 요약을 한 번 보여 줍니다. | 중간 |
| T14 | 수집 공백 | `--last <주기>`는 잠자기·App Nap·지연이 있으면 사이 구간을 놓칩니다. | 설계 분석, `log show --start` 지원(man) | 미탐 | 검사별 마지막 성공 시각을 데몬(root)에 두고 `--start`를 씁니다(상한 포함). 스냅샷 방식의 한계를 문서에 명시합니다. | 중간 |
| T15 | 로그 위조로 경보 피로 | 누구나 `logger`로 인증 실패처럼 보이는 문구를 써서 알림 폭탄을 만들고, 사용자가 알림을 끄게 만듭니다. | 설계 분석 | 알림 무시 유도 | predicate를 메시지 문자열이 아니라 `process`·`subsystem`·`senderImagePath`(시스템 경로)로 겁니다. `--style ndjson`으로 파싱합니다. 알림을 묶고 상한을 둡니다. | 중간 |
| T16 | root의 CLI 실행 | 셸(`/bin/sh -c`, zsh)을 거치면 인젝션과 사용자 rc 파일 로딩 위험이 있습니다. 상대 경로와 상속된 환경도 위험합니다. | [CVE-2024-27822](https://khronokernel.com/macos/2024/06/03/CVE-2024-27822.html) (root zsh가 사용자 `~/.zshenv`를 로드) | root 코드 실행 | `executableURL`에 절대 경로를 쓰고, 인자는 배열로 넘기고, 셸은 쓰지 않습니다. `environment`는 `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `LC_ALL=C`만 명시합니다. 사용자명 같은 값은 검증한 뒤 `--` 뒤에 둡니다. | 중간 (지키면 낮음) |
| T17 | 거대 출력·자원 고갈 | 로그 폭주로 `log show`가 수백 MB를 냅니다. 파이프 64KB를 넘으면 `waitUntilExit`이 교착됩니다. Task 타임아웃은 자식 프로세스를 죽이지 않습니다. `lsof`는 멈출 수 있습니다. 의심 건이 수천 개면 LLM이 GPU·배터리를 소모합니다. | [OWASP LLM10:2025](https://genai.owasp.org/llm-top-10/), [Swift Forums 파이프 교착](https://forums.swift.org/t/the-problem-with-a-frozen-process-in-swift-process-class/39579), `lsof -b`/`-S`(man) | 감시 정지, 맥 느려짐 | 출력은 스트리밍으로 읽고 바이트 상한을 둡니다("잘림" 표시). 타임아웃이면 `terminate()` 후 SIGKILL합니다. `lsof -b -n -P`를 씁니다. 검사별 `Finding` 개수, `evidence` 길이, 응답 크기에 상한을 둡니다. 동시 검사는 1개로 하고 중복 요청은 합칩니다(여러 사용자 포함). LLM 건수·토큰·시간 상한을 넘으면 규칙 판정으로 넘어갑니다. | 중간 |
| T18 | 기록 변조·노출 | `risks.json`(사용자 권한)을 지우거나 고쳐 이력을 숨깁니다. App Sandbox 컨테이너 보호는 쓸 수 없습니다(샌드박스 앱이 등록한 데몬은 샌드박스여야 함). | [Quinn, forum 748124](https://developer.apple.com/forums/thread/748124) | 이력 은폐 | 원본 기록은 데몬이 root 폴더(디렉터리 0700, 파일 0600)에 append합니다. 앱 쪽 파일은 보기용으로 두고 0600을 명시합니다. 이 맥의 `~/Library`는 0700이라 다른 사용자는 읽지 못하는 것을 확인했습니다. | 중간 |
| T19 | 잠금 화면 노출 | 알림 본문에 경로·사용자명·IP·인자가 들어갑니다. | [`hiddenPreviewsBodyPlaceholder`](https://developer.apple.com/documentation/usernotifications/unnotificationcategory/hiddenpreviewsbodyplaceholder) (macOS 10.14+) | 어깨너머 노출 | 본문은 "보안 위험 N건, 패널에서 확인" 수준으로 두고, `hiddenPreviewsBodyPlaceholder`를 설정합니다. | 낮음~중간 |
| T20 | entitlement·서명 | 앱에 `disable-library-validation`, `allow-dyld-environment-variables`, `get-task-allow`가 있으면 dylib 주입으로 데몬에 접속할 수 있습니다. | [NullCon 2021 Reguła/Fitzl](https://theevilbit.github.io/talks_workshops/2021/NullCon2021-Regula-Fitzl-Exploiting-XPC-in-AntiVirus.pdf), [Quinn forum 797913](https://developer.apple.com/forums/thread/797913) (hardened runtime + 예외 entitlement 없음, `kill` 플래그). [MLX 공식 예제 앱](https://github.com/ml-explore/mlx-swift-examples/blob/main/Applications/LLMEval/LLMEval.entitlements)은 hardened runtime + 샌드박스에서 `allow-jit` 없이 동작합니다. | 데몬 접근 탈취 | 두 타깃 모두 `ENABLE_HARDENED_RUNTIME=YES`로 하고 예외 entitlement 0개로 시작합니다. MLX에는 `allow-jit`가 필요 없어 보이지만 실측이 필요합니다. | 중간 |
| T21 | Sparkle 업데이트 | Sparkle 2.7.2 미만은 CVE-2025-10016(root 상승), CVE-2025-10015(Downloader XPC로 TCC 우회)에 걸립니다. | [CERT Polska](https://cert.pl/en/posts/2025/09/CVE-2025-10015/), [NVD 10016](https://nvd.nist.gov/vuln/detail/CVE-2025-10016), [Sparkle 설정 문서](https://sparkle-project.org/documentation/customization/) | root·TCC 우회 | 2.7.2 이상(가능하면 2.9 이상)을 씁니다. `SUPublicEDKey`, HTTPS 피드, `SUVerifyUpdateBeforeExtraction=YES`(2.7.3+), `SURequireSignedFeed=YES`(2.9+)를 설정합니다. 비샌드박스 앱이므로 `SUEnableInstallerLauncherService`와 `SUEnableDownloaderService`는 켜지 않습니다. | 중간 |
| T22 | SPM 공급망 | `.upToNextMinor` 같은 범위 의존성이 자동으로 올라갑니다. 태그가 옮겨질 수 있습니다. 빌드 때 매크로가 실행됩니다(mlx-swift-lm이 swift-syntax 사용). | [arXiv 2601.20638](https://arxiv.org/abs/2601.20638) (iOS 의존성 관리 공급망) | 빌드 산출물 오염 | `Package.resolved`를 커밋합니다(현재 `.gitignore`에서 주석 처리되어 무시되지 않음을 확인). CI는 `xcodebuild -onlyUsePackageVersionsFromResolvedFile`로 빌드합니다. `-skipMacroValidation`, `-skipPackagePluginValidation`은 쓰지 않습니다. | 낮음~중간 |
| T23 | root가 공격자 파일을 파싱 | ④의 `/tmp` 실행 파일 `SecStaticCode` 검사, ②의 사용자 plist 파싱을 root가 합니다. | 직접 사례는 못 찾음 | 확률은 낮고 영향은 큼 | 실행 중 프로세스는 동적 검사 + cdhash 캐시로 처리합니다. plist는 크기 상한을 두고, 사용자 파일 파싱은 사용자 권한 스레드에서 합니다. | 낮음 |

## 3-A. 지금 설계 문서에 넣어야 할 것

- **3-1, 3-2**: `ack(fingerprints)` 2단계 확정과 root 쪽 pending 목록(T2). 지문의 정의와 저장 위치는 데몬, 억제 조건은 "알림 완료"만(T3).
- **D8 개정**: 리스너 단계 요구사항, 위 배포용 문자열, Debug/Release 분리, 최소 버전, 앱도 데몬을 검증, `effectiveUserIdentifier`로 범위 분리(T1, T6).
- **새 결정**: 데몬 XPC API는 경로·명령·predicate 인자를 받지 않습니다. 지금의 무인자 `collect`를 원칙으로 못 박고, 요청 빈도를 제한합니다(FDA를 가진 root 데몬이 남의 요청을 대신 수행하지 않게).
- **새 결정**: 사용자 파일 읽기 규칙(T4)과 CLI 실행 규칙(T16), 출력 상한과 타임아웃 시 프로세스 종료(T17).
- **D10 개정**: LLM 권한 범위, 입력 정규화, 출력 스키마, 알림·패널 표시 규칙(T7, T8).
- **D4 보강**: 모델 고정 목록(커밋 + sha256), 캐시 위치 명시, 허용 목록(T9).
- **`CheckRunner`**: 실패 = `Finding`, 실패한 검사는 기준값 유지, `--start` 사용(T12, T14). 첫 검사 규칙(T13).
- **자기 보호**: `markUserQuit()`, 비정상 종료와 공백 기록, 설정값 검증(T10, T11).
- **D12 개정**: root에 원본 기록. 알림 문구 규칙(T18, T19).
- **데몬 자기 검사**: 자기 번들의 소유자·서명 확인, anti-rollback(T5).
- **9장에 올릴 질문 4개**
  1. 다중 사용자 정책: ① 본인 범위 + 시스템 범위만 ② 관리자는 전체 ③ 관리자만 앱 사용
  2. 설치 방식: ① `.pkg`로 root 소유 설치(업데이트 때 관리자 암호 필요) ② 드래그 설치 + 번들이 쓰기 가능하면 위험으로 표시
  3. LLM 권한: ① 수준을 올리기만 ② 중간→낮음 허용, 기록은 남김
  4. 강제 종료 대응: ① 다음 실행 때 기록만 보여 줌 ② `KeepAlive{SuccessfulExit=false}`로 자동 재실행

## 3-B. 구현·배포 단계에서 할 것

- 두 타깃 hardened runtime을 켜고 공증합니다. 7-1에 `codesign -d --entitlements -`로 예외 entitlement가 0개인지 확인하는 항목을 넣습니다.
- 데몬 서명 identifier를 `com.10000DOO.haetaed`로 고정합니다. 버전마다 바뀌면 [Launch Constraint Violation으로 데몬이 뜨지 않는 사례](https://developer.apple.com/forums/thread/795022)가 있습니다.
- 팀 ID와 최소 버전은 빌드 설정에서 주입합니다. Personal Team에서 유료 팀으로 바꿀 때 팀 ID가 바뀔 수 있습니다.
- Sparkle과 SPM 설정은 T21, T22 대로 합니다.
- `Process` 래퍼는 stdout과 stderr를 모두 비동기로 비우고, 상한·타임아웃·SIGKILL을 넣습니다.
- 실측할 것:
  - 번들 안 `haetaed`를 다른 서명 빌드로 바꿨을 때 launchd가 거부하는지
  - `KeepAlive`가 SIGKILL 종료 뒤 재시작하는지
  - 모델 sha256 검증에 걸리는 시간
  - swift-jinja에서 큰 반복이 있을 때의 동작
- 7-1 테스트 픽스처: 심링크, 하드링크, FIFO, 거대 로그, Unicode 태그 문자 로그.
- 개발이 끝나면 DerivedData 경로로 등록된 root 데몬을 앱에서 `unregister()`합니다. 사용자 쓰기 가능 경로에서 root로 실행되는 상태라서입니다.

## 4. 이미 잘 막혀 있는 것

- **D2**: LLM을 사용자 앱에서 돌려서 root가 외부 문자열을 LLM으로 처리하지 않습니다.
- **D5, D15**: 데몬에 타이머가 없고 필요할 때만 뜹니다. `collect`에 인자가 없어 공격 면이 작습니다.
- **D7**: 기준값이 root 전용 폴더에 있습니다.
- **D8**: Apple이 권장하는 서명 요구사항 방식을 쓰고, `.privileged` 조회라 사용자 도메인에 같은 이름 서비스를 심는 공격이 안 됩니다.
- **D9**: JSON `Data`라 NSCoding 객체 역직렬화 공격면이 없습니다.
- **D10**: 규칙이 "높음"으로 잡은 건은 LLM이 안전이라 해도 위험으로 남습니다.
- **자동 조치 없음**: OWASP LLM06(과도한 권한) 위험이 해당하지 않습니다.
- **MLX 모델 형식**: safetensors라 pickle 실행 위험이 기본적으로 없습니다.

## 5. 확인 못 함

- `setCodeSigningRequirement`가 내부에서 audit token을 쓰는지는 문서에 없습니다. 문서에는 "맞지 않는 메시지가 오면 연결을 끊는다"까지만 있습니다.
- 요구사항 문법(TN3127, csreq)에서 hardened runtime 플래그 자체를 검사하는 항목을 찾지 못했습니다. `info[...] >=`가 숫자 비교인지 사전순 비교인지도 확인하지 못했습니다. `CFBundleVersion`을 고정 자릿수 정수로 쓰는 편이 안전합니다.
- 공개 API로 `NSXPCConnection`의 audit token을 얻는 방법을 찾지 못했습니다.
- SMAppService 데몬에 launchd가 어떤 서명 조건을 거는지 공식 문서가 없습니다. DTS도 LWCR spawn constraint로 "추정"만 했습니다. 등록 뒤 plist를 고치면 다시 읽는지, App Management가 번들 통째 교체를 막는지도 확인하지 못했습니다.
- `O_UNIQUE`, `O_RESOLVE_BENEATH`가 macOS 15.0에서 지원되는지 확인하지 못했습니다. SDK에는 있지만 availability 표기가 없습니다.
- 다른 앱이 AppleEvent quit을 보낼 때 Automation 동의가 필요한지 확인하지 못했습니다.
- 알림 설정 파일을 사용자 권한으로 바꿀 수 있는지, 잠금 화면 미리보기의 기본값이 무엇인지 확인하지 못했습니다.
- swift-huggingface가 다운로드한 내용의 sha256을 검증하는지 확인하지 못했습니다. 코드 검색으로는 찾지 못했고 ETag는 캐시 키로만 쓰입니다.
- 2026년 CVE(39118, 50657, 50658, 24071)와 arXiv 2605.24421은 블로그나 2차 요약을 기준으로 했고, NVD 원문과는 대조하지 못했습니다. Sector 7의 NIB 글은 인증서 오류로 읽지 못했습니다.

실측은 하나도 하지 않았고 전부 문서·코드·웹 자료 기준입니다. T5 번들 교체 실험과 `KeepAlive` 실험 결과에 따라 T5·T11의 우선순위가 바뀔 수 있습니다.
