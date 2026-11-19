// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "HaetaeKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HaetaeShared", targets: ["HaetaeShared"]),
        .library(name: "HaetaeChecks", targets: ["HaetaeChecks"]),
        .library(name: "HaetaeAppCore", targets: ["HaetaeAppCore"]),
    ],
    targets: [
        .target(name: "HaetaeShared"),
        .target(name: "HaetaeChecks", dependencies: ["HaetaeShared"]),
        .target(name: "HaetaeAppCore", dependencies: ["HaetaeShared"]),
        .testTarget(name: "HaetaeChecksTests", dependencies: ["HaetaeChecks"]),
        .testTarget(name: "HaetaeAppCoreTests", dependencies: ["HaetaeAppCore", "HaetaeShared"]),
    ]
)
