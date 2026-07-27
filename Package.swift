// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArkBar",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "ArkBar",
            path: "Sources/ArkBar"),
        .testTarget(
            name: "ArkBarTests",
            dependencies: ["ArkBar"],
            path: "Tests/ArkBarTests"),
    ]
)
