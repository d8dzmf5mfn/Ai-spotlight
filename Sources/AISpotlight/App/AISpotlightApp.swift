import AppKit
import Foundation

/// File-based logger that survives release-build NSLog stripping and
/// SwiftPM executable target quirks. Writes to /tmp so it works regardless
/// of the app's actual working directory, sandbox state, or bundle
/// identity. The /tmp path is the LAST-RESORT diagnostic surface — when
/// everything else (print, NSLog, stderr) has failed, this still works.
///
/// IMPORTANT: any tool that wants to debug launch-time issues in a
/// SwiftPM .app should write its first message via `Log.bootstrap` (the
/// top of main.swift does this) — do NOT wait for class initialization,
/// because Swift 6 strict-concurrency + lazy static initialization has
/// subtle ordering bugs that can silently drop messages.
enum Log {
    /// Path is hardcoded to /tmp so the file is reachable whether the app
    /// is launched from Finder, Terminal, or via NSWorkspace. Caches dir
    /// is sandboxed and may be unwritable in some bundle setups.
    static let url: URL = URL(fileURLWithPath: "/tmp/aispotlight-app.log")

    /// Call this from the very first line of main.swift, before any
    /// framework setup. It writes a single line using the simplest possible
    /// mechanism (Data.write) and avoids the Log enum entirely, so even
    /// if the Log type fails to initialize for any reason, the message
    /// still lands on disk.
    static func bootstrap(_ msg: String) {
        let line = "\(Date()) [bootstrap] \(msg)\n"
        try? Data(line.utf8).write(to: url)
    }

    /// Writes a line to the log. Safe to call from any thread.
    static func write(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        if let h = try? FileHandle(forWritingAtPath: url.path) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
}
