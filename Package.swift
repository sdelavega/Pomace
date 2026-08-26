// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pomace",
    platforms: [.macOS(.v14)],   // see ADR-0012
    products: [
        .library(name: "PomaceCore", targets: ["PomaceCore"]),
        .executable(name: "pomace-spike", targets: ["pomace-spike"]),
        .executable(name: "PomaceApp", targets: ["PomaceApp"]),
    ],
    targets: [
        .target(name: "PomaceCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "pomace-spike", dependencies: ["PomaceCore"]),
        .executableTarget(
            name: "PomaceApp",
            dependencies: ["PomaceCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "PomaceCoreTests", dependencies: ["PomaceCore"]),
    ]
)
