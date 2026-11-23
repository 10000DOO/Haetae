import Foundation
import HaetaeChecks
import HaetaeShared

// 해석 전용 프로세스로 띄워졌으면(WO-47) 리스너·설정 읽기 없이 해석만 하고 끝난다.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--parse" {
    ParserProcess.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
}

let delegate = ListenerDelegate(configuration: DaemonConfiguration.load())
let listener = NSXPCListener(machServiceName: HaetaeXPC.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
