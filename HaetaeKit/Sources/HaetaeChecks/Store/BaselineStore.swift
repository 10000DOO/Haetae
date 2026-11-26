import Foundation
import HaetaeShared

/// 검사별 기준값(D7). 사용자별로 둔다 — 검사는 부른 사용자 범위로 돈다(Q50). 파일은 `baseline/<uid>/<checkID>.json`.
/// 검사는 pending으로 저장하고, 앱이 그 검사의 Finding을 모두 ack하면 확정한다(D24).
public struct BaselineStore: Sendable {
    /// 봉투(`Envelope`) 형식이 바뀌면 올린다. 검사 자기 `data` 형식은 검사마다 `version`으로 따로 둔다(D21).
    public static let schemaVersion = 1
    static let maxBytes = 16_000_000

    private struct Envelope: Codable {
        let schemaVersion: Int
        let checkVersion: Int
        let savedAt: Date
        let data: Data
    }

    /// 버전부터 읽는다 — 봉투에 필드가 더해져도 "다시 학습"으로 가고 영구 실패가 되지 않게.
    private struct Versions: Decodable {
        let schemaVersion: Int
        /// 없으면 버전이 다른 것으로 보고 다시 학습한다.
        let checkVersion: Int?
    }

    private let directory: SecureDirectory

    public init(directory: SecureDirectory) {
        self.directory = directory
    }

    /// 확정된 기준값. 없거나 봉투·검사 형식 버전이 다르면 nil — 그 검사만 첫 실행처럼 다시 학습한다(D21).
    /// - Parameter version: 검사의 기준값 형식 버전(`SecurityCheck.baselineVersion`, WO-11).
    /// - Throws: 버전은 같은데 읽거나 풀 수 없으면 throw한다 — 깨진 기준값을 조용히 다시 학습하면 그때 있던 악성 항목이
    ///   "정상"으로 굳는다(T13). 검사 실패로 드러난다.
    public func load(checkID: String, uid: uid_t, version: Int) throws -> Data? {
        guard let raw = try directory.read(Self.name(checkID), in: Self.folder(uid), maxBytes: Self.maxBytes) else { return nil }
        let versions: Versions = try JSONWire.decode(raw, maxBytes: Self.maxBytes)
        guard versions.schemaVersion == Self.schemaVersion, versions.checkVersion == version else { return nil }
        let envelope: Envelope = try JSONWire.decode(raw, maxBytes: Self.maxBytes)
        return envelope.data
    }

    /// - Throws: 인코딩한 크기가 상한을 넘으면 `tooLarge` — 다시 읽지 못할 기준값으로 확정된 것을 덮지 않는다.
    public func savePending(_ data: Data, checkID: String, uid: uid_t, version: Int) throws {
        let envelope = Envelope(schemaVersion: Self.schemaVersion, checkVersion: version, savedAt: Date(), data: data)
        let encoded = try JSONWire.encode(envelope)
        guard encoded.count <= Self.maxBytes else { throw SecureDirectoryError.tooLarge }
        try directory.write(encoded, to: Self.pendingName(checkID), in: Self.folder(uid))
    }

    /// pending을 확정 기준값으로 바꾼다(원자적). pending이 없으면 아무 일도 하지 않는다.
    /// 그 사용자의 그 검사 pending Finding이 모두 ack됐을 때만 부른다(`FindingLedger.hasPending`).
    public func confirmPending(checkID: String, uid: uid_t) throws {
        do {
            try directory.rename(Self.pendingName(checkID), to: Self.name(checkID), in: Self.folder(uid))
        } catch SecureDirectoryError.system(ENOENT) {
            return
        }
    }

    /// 확정하면 안 되는 pending을 치운다(`<checkID>.json.pending` → `.json.stale`) — pending에서 버린 탐지의 항목이 들어 있어
    /// 뒤에 ack로 확정되면 정상으로 굳는다. 지우는 API가 없어 이름을 바꾼다. 없으면 아무 일도 하지 않는다.
    public func discardPending(checkID: String, uid: uid_t) throws {
        do {
            try directory.rename(Self.pendingName(checkID), to: "\(checkID).json.stale", in: Self.folder(uid))
        } catch SecureDirectoryError.system(ENOENT) {
            return
        }
    }

    /// 깨진 기준값을 옆으로 옮긴다(`<checkID>.json.bad`) — 사람이 root 파일을 지우지 않아도 그 검사가 다시 학습하게.
    /// 옮긴 파일은 무엇이 깨졌는지 볼 수 있게 남긴다. 없으면 아무 일도 하지 않는다.
    public func quarantine(checkID: String, uid: uid_t) throws {
        do {
            try directory.rename(Self.name(checkID), to: "\(checkID).json.bad", in: Self.folder(uid))
        } catch SecureDirectoryError.system(ENOENT) {
            return
        }
    }

    private static func folder(_ uid: uid_t) -> [String] { ["baseline", String(uid)] }
    private static func name(_ checkID: String) -> String { "\(checkID).json" }
    /// `.json`으로 끝나지 않게 해 어떤 checkID의 본 파일과도 이름이 겹치지 않는다.
    private static func pendingName(_ checkID: String) -> String { "\(checkID).json.pending" }
}
