import Foundation
import HaetaeShared

let delegate = ListenerDelegate(configuration: DaemonConfiguration.load())
let listener = NSXPCListener(machServiceName: HaetaeXPC.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
