// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MiraEq",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "MiraEq", targets: ["MiraEq"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "MiraEq",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics")
            ]
        )
    ]
)
