// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AUNViewerClip",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AUNViewerClip", targets: ["AUNViewerClip"])],
    dependencies: [
        .package(path: "../AUNCoreBridge"),
        .package(path: "../AUNDesign"),
        .package(path: "../AUNPlayer"),
    ],
    targets: [
        .target(name: "AUNViewerClip", dependencies: ["AUNCoreBridge", "AUNDesign", "AUNPlayer"]),
        .testTarget(name: "AUNViewerClipTests", dependencies: ["AUNViewerClip"]),
    ]
)
