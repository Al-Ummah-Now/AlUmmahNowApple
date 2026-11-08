// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AUNPlayer",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [.library(name: "AUNPlayer", targets: ["AUNPlayer"])],
    dependencies: [.package(path: "../AUNCoreBridge"), .package(path: "../AUNDesign")],
    targets: [
        .target(name: "AUNPlayer", dependencies: ["AUNCoreBridge", "AUNDesign"]),
        .testTarget(name: "AUNPlayerTests", dependencies: ["AUNPlayer"]),
    ]
)
