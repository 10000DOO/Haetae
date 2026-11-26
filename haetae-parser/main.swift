import Foundation
import HaetaeChecks
import HaetaeShared
import os
import Security

// 서비스가 파일마다 띄운 해석 자식이면 해석만 하고 끝난다.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--parse" {
    ParserProcess.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
}

let log = Logger(subsystem: CodeRequirements.parserIdentifier, category: "service")

#if DEBUG
let variant = CodeRequirements.Variant.debug
#else
let variant = CodeRequirements.Variant.release
#endif

// 실행 파일에 내장된 Info.plist(서명에 묶여 있음)의 값이 자기 서명과 맞는지 보고, 그 값으로 데몬 요구사항을 만든다(데몬과 같은 방식).
// 하나라도 어긋나면 서비스를 열지 않는다 — 요구사항 없이 열면 아무 프로세스나 붙는다.
guard let identity = try? SelfIdentity.load(identifier: CodeRequirements.parserIdentifier),
      let requirement = try? CodeRequirements.daemon(teamID: identity.teamID, minBuild: identity.minBuild, variant: variant),
      CodeRequirements.compileStatus(requirement) == errSecSuccess
else {
    log.fault("자기 신원 확인 실패 — 서비스를 열지 않음")
    exit(78)
}

#if DEBUG
// Q48 확인용(WO-51 7-1): 이 서비스가 TCC가 막는 파일을 열 수 있으면 데몬의 전체 디스크 접근이 따라온 것이다.
// POSIX 권한으로는 누구나 읽을 수 있는 파일이라, 열리지 않으면 TCC가 막은 것이다. 계정과 그룹도 함께 남긴다.
let probe = unsafe open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_CLOEXEC)
let probeResult = probe >= 0 ? "OPENED" : "errno \(errno)"
if probe >= 0 { close(probe) }
var groups = [gid_t](repeating: 0, count: 32)
let groupCount = unsafe getgroups(Int32(groups.count), &groups)
let groupList = groups.prefix(max(0, Int(groupCount))).map { String($0) }.joined(separator: ",")
log.notice("probe: uid \(getuid(), privacy: .public) gid \(getgid(), privacy: .public) groups \(groupList, privacy: .public) TCC.db \(probeResult, privacy: .public)")
#endif
ParserService.run(daemonRequirement: requirement)
