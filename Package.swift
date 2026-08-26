// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pomace",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PomaceCore", targets: ["PomaceCore"]),
        .executable(name: "pomace-spike", targets: ["pomace-spike"]),
    ],
    targets: [
        .target(name: "PomaceCore"),
        .executableTarget(name: "pomace-spike", dependencies: ["PomaceCore"]),
        .testTarget(name: "PomaceCoreTests", dependencies: ["PomaceCore"]),
    ]
)
