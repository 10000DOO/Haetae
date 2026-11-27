/// 데몬이 돌리는 검사 목록. 검사를 더하면 여기에 한 줄을 더한다(D17).
/// 시작할 때 값이 정해지는 검사(`SelfIntegrityCheck`)는 여기 없고 `haetaed/main.swift`가 덧붙인다.
public enum CheckRegistry {
    public static let all: [any SecurityCheck] = [
        SecuritySettingsCheck(),
    ]
}
