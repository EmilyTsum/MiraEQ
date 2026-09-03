// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MiraEQ",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "MiraEQ", targets: ["MiraEQ"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "MiraEQ",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics")
            ]
        ),
        .testTarget(
            name: "MiraEQTests",
            dependencies: ["MiraEQ"]
        )
    ]
)
