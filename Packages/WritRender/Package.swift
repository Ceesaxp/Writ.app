// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WritRender",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WritRender", targets: ["WritRender"])
    ],
    dependencies: [
        .package(path: "../WritCore"),
        .package(path: "../WritParser")
    ],
    targets: [
        .target(
            name: "WritRender",
            dependencies: ["WritCore", "WritParser"],
            path: "Sources/WritRender"
        ),
        .testTarget(
            name: "WritRenderTests",
            dependencies: ["WritRender"],
            path: "Tests/WritRenderTests"
        )
    ]
)
