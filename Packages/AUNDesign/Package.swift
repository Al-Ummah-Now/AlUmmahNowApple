// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AUNDesign",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [.library(name: "AUNDesign", targets: ["AUNDesign"])],
    dependencies: [.package(path: "../AUNCoreBridge")],
    targets: [
        .target(name: "AUNDesign", dependencies: ["AUNCoreBridge"], resources: [.process("Resources")]),
        .testTarget(name: "AUNDesignTests", dependencies: ["AUNDesign"]),
    ]
)
