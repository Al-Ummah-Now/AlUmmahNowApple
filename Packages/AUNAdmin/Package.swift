// swift-tools-version: 6.0
import PackageDescription

// The "Al Ummah Now Admin" app's screens and engines (wiki AUN-ADMIN-NATIVE). Shares Studio's sign-in, the player,
// L10n and the Fanous design; core calls go through AUNCoreBridge protocols.
let package = Package(
    name: "AUNAdmin",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "AUNAdmin", targets: ["AUNAdmin"])],
    dependencies: [
        .package(path: "../AUNCoreBridge"), .package(path: "../AUNDesign"), .package(path: "../AUNPlayer"),
        .package(path: "../AUNStudio"),
    ],
    targets: [
        .target(name: "AUNAdmin", dependencies: ["AUNCoreBridge", "AUNDesign", "AUNPlayer", "AUNStudio"]),
        .testTarget(name: "AUNAdminTests", dependencies: ["AUNAdmin"]),
    ]
)
