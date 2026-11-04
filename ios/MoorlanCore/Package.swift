// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoorlanCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "MoorlanCore", targets: ["MoorlanCore"])
    ],
    targets: [
        .target(name: "MoorlanCore"),
        .testTarget(name: "MoorlanCoreTests", dependencies: ["MoorlanCore"])
    ]
)
