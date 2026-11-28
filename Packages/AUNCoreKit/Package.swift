// swift-tools-version: 6.0
import PackageDescription

// Adapters from the AUNCoreBridge protocols to aun-core (Rust, AlUmmahNowCore). Only the Studio apps link it for now.
let package = Package(
    name: "AUNCoreKit",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [.library(name: "AUNCoreKit", targets: ["AUNCoreKit"])],
    dependencies: [
        .package(path: "../AUNCoreBridge"),
        .package(url: "https://github.com/Al-Ummah-Now/AlUmmahNowCore", exact: "0.4.0-rc.13"),
    ],
    targets: [
        .target(name: "AUNSignalTrap"),
        .target(
            name: "AUNCoreKit",
            dependencies: ["AUNCoreBridge", "AUNSignalTrap", .product(name: "AunCore", package: "AlUmmahNowCore")],
            // The root-signed update key list, byte for byte (its signature covers the exact bytes)
            resources: [.copy("Resources/update-keys.json"), .copy("Resources/update-keys.json.sig")]),
        .testTarget(
            name: "AUNCoreKitTests", dependencies: ["AUNCoreKit"],
            resources: [.copy("Resources/app-update-signed-vector.json")]),
    ]
)
