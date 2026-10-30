// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "HeadBridge",
    products: [
        .executable(name: "headbridge", targets: ["HeadBridge"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "HeadBridge",
            dependencies: [],
            path: "Sources/HeadBridge"
        ),
        .testTarget(
            name: "HeadBridgeTests",
            dependencies: ["HeadBridge"],
            path: "Tests/HeadBridgeTests"
        ),
    ]
)
