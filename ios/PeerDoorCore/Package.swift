// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PeerDoorCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PeerDoorCore", targets: ["PeerDoorCore"])
    ],
    targets: [
        .target(name: "PeerDoorCore"),
        .testTarget(name: "PeerDoorCoreTests", dependencies: ["PeerDoorCore"])
    ]
)
