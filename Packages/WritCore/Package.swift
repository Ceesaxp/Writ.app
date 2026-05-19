// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WritCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WritCore", targets: ["WritCore"])
    ],
    targets: [
        .target(
            name: "WritCore",
            path: "Sources/WritCore"
        ),
        .testTarget(
            name: "WritCoreTests",
            dependencies: ["WritCore"],
            path: "Tests/WritCoreTests"
        )
    ]
)
