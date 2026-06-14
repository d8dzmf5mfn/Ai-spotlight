// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISpotlight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AISpotlight", targets: ["AISpotlight"]),
        .library(name: "AISpotlightKit", targets: ["AISpotlightKit"]),
    ],
    dependencies: [
        // Global hotkey library — wraps Carbon RegisterEventHotKey with a
        // Swift-friendly API. Replaces our hand-rolled (and broken) attempt
        // from Phase 1. See ~/.hermes/skills/macos-global-hotkey-diagnosis
        // for why we abandoned the hand-rolled path.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AISpotlight",
            dependencies: [
                "AISpotlightKit",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/AISpotlight"
        ),
        .target(name: "AISpotlightKit", path: "Sources/AISpotlightKit"),
        .testTarget(
            name: "AISpotlightKitTests",
            dependencies: ["AISpotlightKit"],
            path: "Tests/AISpotlightKitTests"
        ),
    ]
)
