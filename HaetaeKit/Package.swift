// swift-tools-version: 6.4

import PackageDescription

// Xcode 타깃(앱·데몬)과 같은 규칙으로 컴파일한다. 안 맞추면 같은 비동기 함수가
// 패키지에서는 백그라운드에서, 앱에서는 호출한 쪽 actor에서 돈다.
let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ExistentialAny"),
    .strictMemorySafety(),
]

let package = Package(
    name: "HaetaeKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HaetaeShared", targets: ["HaetaeShared"]),
        .library(name: "HaetaeChecks", targets: ["HaetaeChecks"]),
        .library(name: "HaetaeAppCore", targets: ["HaetaeAppCore"]),
    ],
    targets: [
        .target(name: "HaetaeShared", swiftSettings: settings),
        .target(name: "HaetaeChecks", dependencies: ["HaetaeShared"], swiftSettings: settings),
        .target(name: "HaetaeAppCore", dependencies: ["HaetaeShared"], swiftSettings: settings),
        .testTarget(name: "HaetaeSharedTests", dependencies: ["HaetaeShared"], swiftSettings: settings),
        .testTarget(name: "HaetaeChecksTests", dependencies: ["HaetaeChecks", "HaetaeShared"], swiftSettings: settings),
        .testTarget(name: "HaetaeAppCoreTests", dependencies: ["HaetaeAppCore", "HaetaeShared"], swiftSettings: settings),
    ]
)
