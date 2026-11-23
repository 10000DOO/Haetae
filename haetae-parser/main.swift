import Foundation
import HaetaeChecks
import HaetaeShared
import os
import Security

// 서비스가 파일마다 띄운 해석 자식이면 해석만 하고 끝난다.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--parse" {
    ParserProcess.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
}

#if DEBUG
let variant = CodeRequirements.Variant.debug
#else
let variant = CodeRequirements.Variant.release
#endif

// 실행 파일에 내장된 Info.plist(서명에 묶여 있음)의 값으로 데몬 요구사항을 만들고, 그 값이 자기 서명과 맞는지 본다(데몬과 같은 방식).
// 하나라도 어긋나면 서비스를 열지 않는다 — 요구사항 없이 열면 아무 프로세스나 붙는다.
let info = Bundle.main.infoDictionary ?? [:]
guard info["CFBundleIdentifier"] as? String == CodeRequirements.parserIdentifier,
      let teamID = info["HaetaeTeamID"] as? String,
      let minBuild = (info["HaetaeMinBuild"] as? String).flatMap(Int.init),
      let requirement = try? CodeRequirements.daemon(teamID: teamID, minBuild: minBuild, variant: variant),
      CodeRequirements.compileStatus(requirement) == errSecSuccess,
      (try? CodeRequirements.selfSignatureStatus(teamID: teamID, minBuild: minBuild)) == errSecSuccess
else {
    Logger(subsystem: CodeRequirements.parserIdentifier, category: "service").fault("자기 신원 확인 실패 — 서비스를 열지 않음")
    exit(78)
}
ParserService.run(daemonRequirement: requirement)
