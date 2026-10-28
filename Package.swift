// swift-tools-version: 5.10

import PackageDescription

#if os(macOS)
let package = Package(
    name: "HeadBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HeadBridge", targets: ["HeadBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5")
    ],
    targets: [
        .executableTarget(
            name: "HeadBridge",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/HeadBridge"
        ),
        .testTarget(
            name: "HeadBridgeTests",
            dependencies: ["HeadBridge"],
            path: "Tests/HeadBridgeTests"
        ),
    ]
)
#else
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
#endif
