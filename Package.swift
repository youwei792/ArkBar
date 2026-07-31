// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/steipete/SweetCookieKit", exact: "0.4.1"),
    ],
    targets: [
        .executableTarget(
            name: "TokenBar",
            dependencies: [
                .product(name: "SweetCookieKit", package: "SweetCookieKit"),
            ],
            path: "Sources/TokenBar"),
        .testTarget(
            name: "TokenBarTests",
            dependencies: ["TokenBar"],
            path: "Tests/TokenBarTests"),
    ]
)
