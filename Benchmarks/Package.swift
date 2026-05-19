// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WritBenchmarks",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "writ-fixtures", targets: ["FixtureGenerator"]),
        .executable(name: "writ-bench", targets: ["BenchmarkRunner"])
    ],
    dependencies: [
        .package(path: "../Packages/WritCore"),
        .package(path: "../Packages/WritParser"),
        .package(path: "../Packages/WritRender")
    ],
    targets: [
        .executableTarget(
            name: "FixtureGenerator",
            dependencies: [],
            path: "Sources/FixtureGenerator"
        ),
        .executableTarget(
            name: "BenchmarkRunner",
            dependencies: ["WritCore", "WritParser", "WritRender"],
            path: "Sources/BenchmarkRunner"
        )
    ]
)
