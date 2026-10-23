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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "PomaceCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "pomace-spike", dependencies: ["PomaceCore"]),
        .executableTarget(
            name: "PomaceApp",
            dependencies: ["PomaceCore", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.process("Resources")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "PomaceCoreTests", dependencies: ["PomaceCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "PomaceAppTests", dependencies: ["PomaceApp", "PomaceCore"]),
    ]
)
