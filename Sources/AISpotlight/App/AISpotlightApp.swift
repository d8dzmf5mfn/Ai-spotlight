import AppKit
import Foundation

/// File-based logger — NSLog is stripped in release builds with the
/// private log subsystem, and `print` to stderr can be lost when the app
/// is launched via Finder/.app. Writing to a file in the user's cache dir
/// always works.
enum Log {
    static let url: URL = URL(fileURLWithPath: "/tmp/aispotlight-app.log")
    static func write(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}
