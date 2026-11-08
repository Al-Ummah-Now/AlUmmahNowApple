// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AUNStudio",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [.library(name: "AUNStudio", targets: ["AUNStudio"])],
    dependencies: [.package(path: "../AUNCoreBridge"), .package(path: "../AUNDesign")],
    targets: [
        .target(name: "AUNStudio", dependencies: ["AUNCoreBridge", "AUNDesign"]),
        .testTarget(name: "AUNStudioTests", dependencies: ["AUNStudio"]),
    ]
)
