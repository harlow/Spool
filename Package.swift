// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Spool",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Spool", targets: ["Spool"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9")
    ],
    targets: [
        .executableTarget(
            name: "Spool",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Spool",
            exclude: ["Info.plist", "Spool.entitlements", "Assets"]
        )
    ]
)
