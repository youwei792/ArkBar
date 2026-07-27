// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArkBar",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/steipete/SweetCookieKit", exact: "0.4.1"),
    ],
    targets: [
        .executableTarget(
            name: "ArkBar",
            dependencies: [
                .product(name: "SweetCookieKit", package: "SweetCookieKit"),
            ],
            path: "Sources/ArkBar"),
        .testTarget(
            name: "ArkBarTests",
            dependencies: ["ArkBar"],
            path: "Tests/ArkBarTests"),
    ]
)
