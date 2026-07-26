// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageWidget",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeUsageWidget", targets: ["ClaudeUsageWidget"])
    ],
    targets: [
        .executableTarget(
            name: "ClaudeUsageWidget",
            path: "Sources/ClaudeUsageWidget",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudeUsageWidgetTests",
            dependencies: ["ClaudeUsageWidget"],
            path: "Tests/ClaudeUsageWidgetTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
