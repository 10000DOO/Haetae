import Foundation
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

let delegate = ListenerDelegate(configuration: DaemonConfiguration.load())
let listener = NSXPCListener(machServiceName: HaetaeXPC.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
