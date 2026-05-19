// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WritParser",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WritParser", targets: ["WritParser"])
    ],
    dependencies: [
        .package(path: "../WritCore"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.6.0")
    ],
    targets: [
        .target(
            name: "WritParser",
            dependencies: [
                "WritCore",
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Sources/WritParser"
        ),
        .testTarget(
            name: "WritParserTests",
            dependencies: ["WritParser"],
            path: "Tests/WritParserTests"
        )
    ]
)
