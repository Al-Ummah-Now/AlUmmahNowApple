// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AUNCoreBridge",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [.library(name: "AUNCoreBridge", targets: ["AUNCoreBridge"])],
    dependencies: [],
    targets: [
        .target(name: "AUNCoreBridge", dependencies: []),
        .testTarget(name: "AUNCoreBridgeTests", dependencies: ["AUNCoreBridge"]),
    ]
)
