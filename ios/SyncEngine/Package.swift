// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SyncEngine",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SyncEngine", targets: ["SyncEngine"])
    ],
    targets: [
        .target(name: "SyncEngine"),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine"])
    ]
)
