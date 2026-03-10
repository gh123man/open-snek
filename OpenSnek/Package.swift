// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenSnek",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OpenSnekCore", targets: ["OpenSnekCore"]),
        .library(name: "OpenSnekProtocols", targets: ["OpenSnekProtocols"]),
        .library(name: "OpenSnekHardware", targets: ["OpenSnekHardware"]),
        .library(name: "OpenSnekAppSupport", targets: ["OpenSnekAppSupport"]),
        .executable(name: "OpenSnek", targets: ["OpenSnek"]),
        .executable(name: "OpenSnekProbe", targets: ["OpenSnekProbe"])
    ],
    targets: [
        .target(
            name: "OpenSnekCore",
            path: "Sources/OpenSnekCore"
        ),
        .target(
            name: "OpenSnekProtocols",
            dependencies: ["OpenSnekCore"],
            path: "Sources/OpenSnekProtocols"
        ),
        .target(
            name: "OpenSnekHardware",
            dependencies: ["OpenSnekCore", "OpenSnekProtocols"],
            path: "Sources/OpenSnekHardware"
        ),
        .target(
            name: "OpenSnekAppSupport",
            dependencies: ["OpenSnekCore", "OpenSnekHardware"],
            path: "Sources/OpenSnekAppSupport"
        ),
        .executableTarget(
            name: "OpenSnek",
            dependencies: ["OpenSnekCore", "OpenSnekProtocols", "OpenSnekHardware", "OpenSnekAppSupport"],
            path: "Sources/OpenSnek"
        ),
        .executableTarget(
            name: "OpenSnekProbe",
            dependencies: ["OpenSnekCore", "OpenSnekProtocols", "OpenSnekHardware"],
            path: "Sources/OpenSnekProbe"
        ),
        .testTarget(
            name: "OpenSnekTests",
            dependencies: ["OpenSnek", "OpenSnekCore", "OpenSnekProtocols", "OpenSnekHardware", "OpenSnekAppSupport"],
            path: "Tests/OpenSnekTests"
        ),
    ]
)
