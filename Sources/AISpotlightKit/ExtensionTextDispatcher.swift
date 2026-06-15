import Foundation

/// A pluggable text extractor for a specific file extension. The
/// Core (Foundation-only) `ContentIndexer` looks up the file's
/// extension in `IndexStore.dispatchers` and calls `extract(url)` if
/// a dispatcher is registered.
///
/// **Why a protocol (not a closure):** the AppKit-backed
/// `RichTextExtractor` lives in the separate `AISpotlightMac` library
/// target. Core can't import AppKit, so it can't directly call
/// NSAttributedString. The protocol is the seam that lets the App
/// target wire AppKit-bridged extractors in without dragging AppKit
/// into the Core test target (which deadlocks the XCTest host on
/// macOS 27 beta — see `~/.hermes/skills/macos-swiftpm-bug-hang`).
///
/// **Implemented by** the App target's adapter, which forwards to
/// `RichTextExtractor.extract` (the actual NSAttributedString code).
public protocol ExtensionTextDispatcher: Sendable {
    /// Read the file at `url` and return its extracted text.
    /// Implementations should return lowercased text so the
    /// downstream `TextExtractor.tokenize` matches as expected.
    /// Throws if the file can't be opened; the indexer will skip
    /// the file in that case.
    func extract(_ url: URL) throws -> String
}
