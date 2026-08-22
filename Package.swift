// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlStudio",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "BlStudio",
            path: "Sources/BlStudio",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "BlStudioTests",
            dependencies: ["BlStudio"],
            path: "Tests/BlStudioTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
