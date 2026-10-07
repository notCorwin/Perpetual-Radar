// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PerpetualRadar",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .systemLibrary(name: "CZlib"),
        .executableTarget(name: "PerpetualRadar", dependencies: ["CSQLite", "CZlib", "ZIPFoundation"]),
        .testTarget(name: "PerpetualRadarTests", dependencies: ["PerpetualRadar"]),
    ]
)
