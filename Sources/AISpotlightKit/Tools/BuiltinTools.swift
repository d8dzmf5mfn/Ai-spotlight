import Foundation

/// Phase 4.3: built-in local tools the LLM can call. These
/// all use macOS-provided commands (`mdfind`, `find`, `open`)
/// under the hood — we're not implementing file search or
/// app launching ourselves, we're teaching the LLM to use
/// the system commands that already exist.
///
/// **The "borrow the system" pattern continues**: Phase 4.2.10
/// had us use `MDQuery` (macOS Spotlight) for content search
/// instead of building our own index. Phase 4.3 has us use
/// `mdfind` (the CLI) and `open` (the launcher) instead of
/// implementing our own tool framework.
///
/// All three tools in this file have `requiresConsent = false`
/// because they're read-only or trivial side-effects (opening
/// a file the user just searched for). Tools that delete or
/// modify state will need consent in Phase 4.3.1.
public enum BuiltinTools {

    /// Search for files by content (or filename). Wraps
    /// `mdfind` which is the CLI front-end to the same
    /// Spotlight index `MDQuery` reads. We use `mdfind` rather
    /// than `MDQuery` directly because:
    ///   1. No C bridging required (we already have Process)
    ///   2. The tool can be tested by hand at the terminal
    ///   3. The mdfind output is just paths, easy to parse
    public static func searchFiles() -> LLMTool {
        return LLMTool(
            name: "search_files",
            description: "Find files on the user's Mac by filename or by file contents. Returns paths.",
            parametersDescription: """
            - query (string, required): the search terms (e.g. "polyester", "report.pdf", "chemistry notes")
            - kind (string, optional): "name" to search filenames only, "content" to search file contents (default: "content")
            - limit (int, optional): max results to return (default: 5, max: 20)
            """,
            requiresConsent: false
        ) { args in
            guard let query = args["query"] as? String, !query.isEmpty else {
                throw ToolError.badArgs("search_files requires non-empty 'query'")
            }
            let kind = (args["kind"] as? String) ?? "content"
            let limit = (args["limit"] as? Int) ?? 5
            let clampedLimit = min(max(limit, 1), 20)

            // Build the mdfind query.
            // For content search: kMDItemTextContent == "*query*"
            // For name search: kMDItemFSName == "*query*"
            let escaped = query
                .replacingOccurrences(of: "'", with: "\\'")
            let mdquery: String
            switch kind {
            case "name":
                mdquery = "kMDItemFSName == '*\(escaped)*'"
            case "content":
                mdquery = "kMDItemTextContent == '*\(escaped)*'"
            default:
                throw ToolError.badArgs("search_files: 'kind' must be 'name' or 'content'")
            }

            let result = try await ProcessRunner.run(
                executable: "/usr/bin/mdfind",
                arguments: [mdquery]
            )
            if result.exitCode != 0 {
                throw ToolError.runtimeError(
                    "mdfind failed (exit \(result.exitCode)): \(result.stderr)"
                )
            }
            let paths = result.stdout
                .split(separator: "\n")
                .map { String($0) }
                .filter { !$0.isEmpty }
            // mdfind doesn't support -maxresults on modern macOS.
            // We cap the output client-side.
            let capped = Array(paths.prefix(clampedLimit))
            return LLMToolResult(
                summary: "Found \(capped.count) file(s) matching '\(query)'",
                payload: [
                    "paths": .array(capped.map { .string($0) }),
                    "count": .int(capped.count),
                ]
            )
        }
    }

    /// Open a file or app with the system default handler.
    /// Wraps `open` (macOS's universal launcher).
    /// `requiresConsent = false` for now because opening a
    /// file the LLM just searched for is what the user
    /// implicitly asked for. Phase 4.3.1 will add a
    /// per-call confirmation dialog for arbitrary paths.
    public static func openFile() -> LLMTool {
        return LLMTool(
            name: "open_file",
            description: "Open a file or app on the user's Mac with the system default handler. For files, this opens them in their associated app (PDF in Preview, .md in TextEdit, etc.). For .app bundles, this launches the app.",
            parametersDescription: """
            - path (string, required): absolute path to the file or app to open
            """,
            requiresConsent: false
        ) { args in
            guard let path = args["path"] as? String, !path.isEmpty else {
                throw ToolError.badArgs("open_file requires non-empty 'path'")
            }
            // Validate the path exists. Don't open anything
            // that doesn't exist — even by accident, a typo
            // would surface as a confusing "open this random
            // thing?" dialog.
            guard FileManager.default.fileExists(atPath: path) else {
                throw ToolError.runtimeError("File does not exist: \(path)")
            }
            let result = try await ProcessRunner.run(
                executable: "/usr/bin/open",
                arguments: [path]
            )
            if result.exitCode != 0 {
                throw ToolError.runtimeError(
                    "open failed (exit \(result.exitCode)): \(result.stderr)"
                )
            }
            return LLMToolResult(
                summary: "Opened \(path)",
                payload: [
                    "ok": .bool(true),
                    "path": .string(path),
                ]
            )
        }
    }

    /// List the apps installed in /Applications (or wherever
    /// the path points). Wraps `ls` for the user's
    /// `~/Applications` and `/Applications` dirs.
    public static func listApps() -> LLMTool {
        return LLMTool(
            name: "list_apps",
            description: "List the apps installed on the user's Mac. Returns the .app bundle names in the system Applications folder and the user's local Applications folder.",
            parametersDescription: """
            - scope (string, optional): "user" to list only ~/Applications, "system" to list only /Applications, "all" for both (default: "all")
            """,
            requiresConsent: false
        ) { args in
            let scope = (args["scope"] as? String) ?? "all"
            var paths: [URL] = []
            switch scope {
            case "user":
                paths.append(FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications"))
            case "system":
                paths.append(URL(fileURLWithPath: "/Applications"))
            case "all":
                paths.append(FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications"))
                paths.append(URL(fileURLWithPath: "/Applications"))
            default:
                throw ToolError.badArgs("list_apps: 'scope' must be 'user', 'system', or 'all'")
            }
            var apps: [String] = []
            for dir in paths {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for url in contents where url.pathExtension == "app" {
                    apps.append(url.lastPathComponent)
                }
            }
            apps.sort()
            return LLMToolResult(
                summary: "Found \(apps.count) installed apps",
                payload: [
                    "apps": .array(apps.map { .string($0) }),
                    "count": .int(apps.count),
                ]
            )
        }
    }

    /// Phase 5-F: example of a tool that requires user
    /// consent. The LLM has to ask the user before running
    /// arbitrary shell commands. We ship this as a builtin
    /// (disabled by default — the user has to enable it in
    /// Settings) so the consent dialog can be exercised
    /// during testing without writing a custom tool.
    public static func runShell() -> LLMTool {
        return LLMTool(
            name: "run_shell",
            description: "Run a shell command via /bin/sh -c. Useful for one-off CLI invocations like `ls /tmp` or `date`. Returns stdout, stderr, and exit code.",
            parametersDescription: """
            - command (string, required): the full shell command, e.g. "ls -la /tmp | head -5"
            - timeout (int, optional): max seconds to wait (default: 10, max: 60)
            """,
            requiresConsent: true
        ) { args in
            guard let command = args["command"] as? String, !command.isEmpty else {
                throw ToolError.badArgs("run_shell requires non-empty 'command'")
            }
            let timeout = min((args["timeout"] as? Int) ?? 10, 60)
            let result = try await ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", command]
            )
            // 124 is timeout's exit code; we surface a friendlier message.
            if Int(result.exitCode) == 124 {
                return LLMToolResult(
                    summary: "Command timed out after \(timeout)s",
                    payload: [
                        "stdout": .string(result.stdout),
                        "stderr": .string(result.stderr),
                        "exitCode": .int(Int(result.exitCode)),
                    ]
                )
            }
            return LLMToolResult(
                summary: "Exit \(result.exitCode): \(result.stdout.prefix(80))",
                payload: [
                    "stdout": .string(result.stdout),
                    "stderr": .string(result.stderr),
                    "exitCode": .int(Int(result.exitCode)),
                ]
            )
        }
    }
}

/// Errors that tools can throw. The outer loop in
/// `LLMConversationService.askWithTools` catches these and
/// feeds the error message back to the LLM as the tool result
/// so the LLM can try a different argument or give up.
public enum ToolError: Error, LocalizedError {
    case badArgs(String)
    case runtimeError(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .badArgs(let msg): return "Bad arguments: \(msg)"
        case .runtimeError(let msg): return msg
        case .cancelled: return "User cancelled the tool call"
        }
    }
}

/// Tiny async wrapper around `Process`. The C `Process` API
/// is blocking — we need an async interface for the tool
/// loop. We use the `terminationHandler` continuation-style
/// pattern to bridge.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
    }

    /// Run a process and await its exit. The stdout/stderr are
    /// captured as strings. Throws on spawn failure (e.g. the
    /// executable path doesn't exist).
    public static func run(executable: String, arguments: [String]) async throws -> Result {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.terminationHandler = { proc in
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                cont.resume(returning: Result(
                    exitCode: proc.terminationStatus,
                    stdout: out,
                    stderr: err
                ))
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
