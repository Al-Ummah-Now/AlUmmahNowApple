// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AUNViewerClip",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AUNViewerClip", targets: ["AUNViewerClip"])],
    targets: [
        .target(name: "AUNViewerClip"),
        .testTarget(name: "AUNViewerClipTests", dependencies: ["AUNViewerClip"]),
    ]
)
