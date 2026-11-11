// swift-tools-version: 6.0
import PackageDescription

// Adapters from the AUNCoreBridge protocols to aun-core (Rust, AlUmmahNowCore). Only the Studio apps link it for now.
let package = Package(
    name: "AUNCoreKit",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [.library(name: "AUNCoreKit", targets: ["AUNCoreKit"])],
    dependencies: [
        .package(path: "../AUNCoreBridge"),
        .package(url: "https://github.com/Al-Ummah-Now/AlUmmahNowCore", exact: "0.3.0-rc.1"),
    ],
    targets: [
        .target(
            name: "AUNCoreKit",
            dependencies: ["AUNCoreBridge", .product(name: "AunCore", package: "AlUmmahNowCore")]),
        .testTarget(name: "AUNCoreKitTests", dependencies: ["AUNCoreKit"]),
    ]
)
