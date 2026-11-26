import Foundation
import HaetaeShared

/// 데몬이 시작할 때 본 자기 번들 검사 결과(D20)를 사용자마다 "Haetae 변조"(높음)로 알린다. 번들 읽기는 `main`이 한 번 한다 —
/// 여기서는 그 값만 낸다. 문제가 없으면 아무것도 내지 않아, 전에 알린 것은 고쳐진 뒤 해결로 간다.
/// 실행 중에 생긴 변조는 다음에 데몬이 뜰 때 잡는다(시작 때만 본다 — D20).
public struct SelfIntegrityCheck: SecurityCheck {
    public let id = "haetae.self-integrity"
    public let timeout: Duration = .seconds(1)
    public let needsBaseline = false
    public let baselineVersion = 1
    private let problems: [BundleIntegrity.Problem]

    public init(problems: [BundleIntegrity.Problem]) {
        self.problems = problems
    }

    public func run(_ ctx: CheckContext) async throws -> CheckResult {
        guard !problems.isEmpty else { return CheckResult(findings: []) }
        // 문제마다 지문이 달라진다 — 소유 문제를 확인한 뒤 서명까지 깨지면 다시 알린다.
        let reasons = problems.map(\.reason).joined(separator: " ")
        return CheckResult(findings: [Finding(
            checkID: id, title: "Haetae 변조", evidence: "Haetae 앱 번들이 바뀌었거나 root가 아닌 사용자가 바꿀 수 있습니다. \(reasons)",
            ruleLevel: .high, fingerprint: Fingerprint.make(checkID: id, subject: "bundle", contentHash: reasons), observedAt: Date()
        )])
    }
}

extension BundleIntegrity.Problem {
    /// Finding과 원장 기록(`selfIntegrityFailed`)이 같은 글을 쓴다.
    var reason: String {
        switch self {
        case .unreadable: "번들 안을 다 읽지 못했습니다."
        case .notRootOwned(let path): "root 소유가 아닌 항목: \(path)"
        case .writableByOthers(let path): "그룹·기타 사용자가 쓸 수 있는 항목: \(path)"
        case .hasACL(let path): "ACL이 붙은 항목: \(path)"
        case .invalidSignature(let status): "서명이 맞지 않습니다 (코드 \(status))."
        }
    }
}
