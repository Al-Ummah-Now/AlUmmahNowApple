// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AUNFeatures",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [.library(name: "AUNFeatures", targets: ["AUNFeatures"])],
    dependencies: [
        .package(path: "../AUNCoreBridge"),
        .package(path: "../AUNDesign"),
        .package(path: "../AUNPlayer"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(name: "AUNFeatures", dependencies: ["AUNCoreBridge", "AUNDesign", "AUNPlayer"]),
        .testTarget(
            name: "AUNFeaturesTests",
            dependencies: [
                "AUNFeatures",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"]
        ),
    ]
)
