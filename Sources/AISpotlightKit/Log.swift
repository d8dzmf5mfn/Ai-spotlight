import Foundation

/// Lightweight file-based logger used by both the App and the
/// ContentIndexer (which lives in Core and can't import the App
/// target's symbols). Writes to `/tmp/aispotlight-app.log` so it's
/// always reachable regardless of where the .app is launched from.
///
/// **Design note:** we use a per-line `FileHandle(forWritingAtPath:)`
/// + `seekToEndOfFile` rather than keeping a long-lived handle.
/// Trade-off: more syscalls per line, but no risk of a leaked
/// descriptor and no need to coordinate close/flush from many
/// threads. For a log of a few hundred lines per app run, the
/// syscall cost is invisible.
public enum Log {
    public static let url: URL = URL(fileURLWithPath: "/tmp/aispotlight-app.log")

    /// Truncate the log on bootstrap. Call this from the very
    /// first line of main.swift, before any framework setup, so a
    /// crashed previous run doesn't pollute the new run.
    public static func bootstrap(_ msg: String) {
        let line = "\(Date()) [bootstrap] \(msg)\n"
        try? Data(line.utf8).write(to: url)
    }

    /// Append a line to the log. Safe to call from any thread.
    /// Uses fsync so debug logs are visible immediately when
    /// tailing the file — the in-memory `FileHandle` close
    /// path was buffering output and we lost debugging context
    /// during Phase 4.1 bring-up.
    public static func write(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        guard let h = try? FileHandle(forWritingAtPath: url.path) else { return }
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.synchronize()  // force fsync
        try? h.close()
    }
}
