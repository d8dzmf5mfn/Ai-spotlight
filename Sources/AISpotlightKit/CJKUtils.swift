import Foundation

/// Utility for detecting CJK (Chinese/Japanese/Korean) characters.
/// Used to decide which search path to take.
public enum CJKUtils {
    /// Returns true if the string contains any CJK Unified Ideographs
    /// (U+4E00–U+9FFF), CJK Unified Ideographs Extension A (U+3400–U+4DBF),
    /// or CJK Compatibility Ideographs (U+F900–U+FAFF).
    public static func containsCJK(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            // CJK Unified Ideographs
            (0x4E00...0x9FFF).contains(scalar.value) ||
            // CJK Unified Ideographs Extension A
            (0x3400...0x4DBF).contains(scalar.value) ||
            // CJK Compatibility Ideographs
            (0xF900...0xFAFF).contains(scalar.value) ||
            // CJK Unified Ideographs Extension B
            (0x20000...0x2A6DF).contains(scalar.value) ||
            // CJK Compatibility Ideographs Supplement
            (0x2F800...0x2FA1F).contains(scalar.value) ||
            // Hiragana (Japanese)
            (0x3040...0x309F).contains(scalar.value) ||
            // Katakana (Japanese)
            (0x30A0...0x30FF).contains(scalar.value) ||
            // Hangul Syllables (Korean)
            (0xAC00...0xD7AF).contains(scalar.value) ||
            // Hangul Jamo
            (0x1100...0x11FF).contains(scalar.value)
        }
    }

    /// Returns true if the string contains any non-ASCII characters
    /// commonly found in CJK text, including full-width punctuation.
    public static func containsNonASCII(_ string: String) -> Bool {
        string.unicodeScalars.contains { !$0.isASCII }
    }
}
