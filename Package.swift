// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PerpetualRadar",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(name: "PerpetualRadar", dependencies: ["CSQLite"]),
        .testTarget(name: "PerpetualRadarTests", dependencies: ["PerpetualRadar"]),
    ]
)
