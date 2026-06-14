// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISpotlight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AISpotlight", targets: ["AISpotlight"]),
        .library(name: "AISpotlightKit", targets: ["AISpotlightKit"]),
    ],
    targets: [
        .executableTarget(
            name: "AISpotlight",
            dependencies: ["AISpotlightKit"],
            path: "Sources/AISpotlight"
        ),
        .target(name: "AISpotlightKit", path: "Sources/AISpotlightKit"),
        // Test target re-enabled in Task 3
    ]
)
