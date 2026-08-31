// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexQuota",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexMeter", targets: ["CodexMeter"]),
        .library(name: "CodexMeterCore", targets: ["CodexMeterCore"])
    ],
    targets: [
        .executableTarget(
            name: "CodexMeter",
            dependencies: ["CodexMeterCore"]
        ),
        .target(
            name: "CodexMeterCore"
        ),
        .testTarget(
            name: "CodexMeterCoreTests",
            dependencies: ["CodexMeterCore"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "CodexMeterTests",
            dependencies: ["CodexMeter", "CodexMeterCore"]
        )
    ]
)
