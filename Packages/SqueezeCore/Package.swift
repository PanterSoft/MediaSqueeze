// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SqueezeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SqueezeCore", targets: ["SqueezeCore"]),
    ],
    targets: [
        .target(name: "SqueezeCore"),
        .testTarget(name: "SqueezeCoreTests", dependencies: ["SqueezeCore"]),
    ]
)
