import Foundation
import HaetaeChecks
import HaetaeShared
import os

#if DEBUG
// WO-51 7-1의 대조군: 전체 디스크 접근을 준 뒤 데몬은 열려야(OPENED) 해석 서비스의 "errno 1"이 의미가 있다.
// 데몬도 못 열면 권한을 준 방식이 틀린 것이라 측정이 무효다.
let probe = unsafe open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_CLOEXEC)
let probeResult = probe >= 0 ? "OPENED" : "errno \(errno)"
if probe >= 0 { close(probe) }
Log.service.notice("probe: uid \(getuid(), privacy: .public) TCC.db \(probeResult, privacy: .public)")
#endif

let configuration = DaemonConfiguration.load()
let directory = SecureDirectory()
let ledger = FindingLedger(directory: directory)

// 시작할 때 한 번 자기 번들을 본다(D20). 요구사항이 없으면 어차피 모든 연결을 거부한다.
let selfIntegrity = configuration.appRequirement.map { BundleIntegrity.problems(in: Bundle.main.bundleURL, requirement: $0) } ?? []
if !selfIntegrity.isEmpty { Log.listener.fault("자기 번들 검사 실패 (\(selfIntegrity.count)건)") }

// Debug는 `highest-build`를 읽지도 쓰지도 않는다(Q34 — Debug와 Release가 같은 root 폴더를 쓴다). 신원 확인에 실패해 빌드를
// 모르면(모든 연결 거부) 건드리지 않는다 — 0을 기록하거나 "되돌린 빌드"로 잘못 적지 않게.
let highestBuild = configuration.variant == .release && configuration.appRequirement != nil
    ? HighestBuild.update(running: configuration.build, in: directory) : nil

// Debug에만 데모 검사를 더한다(WO-54 — 위험 화면 체험용, Release에는 없다).
#if DEBUG
let debugChecks: [any SecurityCheck] = [DemoRiskCheck()]
#else
let debugChecks: [any SecurityCheck] = []
#endif

// `CommandRunner`는 데몬 전체에서 하나만 만든다 — 직렬화가 인스턴스 단위라 연결마다 만들면 D26의 "동시 1개"가 깨진다.
let checkRunner = CheckRunner(
    checks: CheckRegistry.all + [SelfIntegrityCheck(problems: selfIntegrity)] + debugChecks, baseline: BaselineStore(directory: directory), ledger: ledger,
    runner: CommandRunner(), parser: configuration.parser, daemonBuild: configuration.build
)
let coordinator = CollectCoordinator(
    runner: checkRunner, ledger: ledger, build: configuration.build, highestBuild: highestBuild, selfIntegrity: selfIntegrity
)
if coordinator.isRolledBack { Log.listener.fault("되돌린 빌드 — 모든 요청 거부") }

let delegate = ListenerDelegate(configuration: configuration, coordinator: coordinator)
// launchd가 bootout·시스템 종료 때 보내는 SIGTERM에서도 묶어 둔 기록을 적고 끝낸다(SIGKILL까지 기본 20초).
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM)
termination.setEventHandler {
    Task {
        await coordinator.prepareForExit()
        DaemonExit.now()
    }
}
termination.resume()

let listener = NSXPCListener(machServiceName: HaetaeXPC.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
