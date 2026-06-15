// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISpotlight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AISpotlight", targets: ["AISpotlight"]),
        .library(name: "AISpotlightKit", targets: ["AISpotlightKit"]),
        .library(name: "AISpotlightMac", targets: ["AISpotlightMac"]),
    ],
    dependencies: [
        // Global hotkey library — wraps Carbon RegisterEventHotKey with a
        // Swift-friendly API. Replaces our hand-rolled (and broken) attempt
        // from Phase 1. See ~/.hermes/skills/macos-global-hotkey-diagnosis
        // for why we abandoned the hand-rolled path.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
    ],
    targets: [
        // Core: Foundation only. No AppKit imports. The test target
        // for this layer runs cleanly on macOS 27 beta.
        .target(
            name: "AISpotlightKit",
            path: "Sources/AISpotlightKit"
        ),
        // Mac: AppKit-bridged extensions (RichTextExtractor via
        // NSAttributedString). Split out of Core to keep the Core
        // test target free of AppKit, which is the trigger for
        // a known macOS 27 beta regression where the XCTest host
        // process deadlocks during AppKit initialization.
        // See ~/.hermes/skills/macos-swiftpm-bug-hang.
        .target(
            name: "AISpotlightMac",
            dependencies: ["AISpotlightKit"],
            path: "Sources/AISpotlightMac"
        ),
        .executableTarget(
            name: "AISpotlight",
            dependencies: [
                "AISpotlightKit",
                "AISpotlightMac",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/AISpotlight"
        ),
        .testTarget(
            name: "AISpotlightKitTests",
            dependencies: ["AISpotlightKit"],
            path: "Tests/AISpotlightKitTests"
        ),
    ]
)
