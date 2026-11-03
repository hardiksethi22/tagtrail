// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TagTrail",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TagTrailCore", targets: ["TagTrailCore"]),
        .executable(name: "TagTrail", targets: ["TagTrail"]),
        .executable(name: "CoreChecks", targets: ["CoreChecks"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "TagTrailCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "TagTrail", dependencies: ["TagTrailCore"], path: "App"),
        .executableTarget(name: "CoreChecks", dependencies: ["TagTrailCore", "CSQLite"], path: "Checks"),
        .testTarget(name: "TagTrailCoreTests", dependencies: ["TagTrailCore"]),
        .testTarget(name: "TagTrailAppTests", dependencies: ["TagTrail", "TagTrailCore"],
                    path: "AppTests",
                    exclude: ["protocol-v1.json", "worker-fixture.sh"]),
    ]
)
