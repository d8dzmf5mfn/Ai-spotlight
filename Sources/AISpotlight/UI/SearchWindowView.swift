import SwiftUI
import AISpotlightKit

struct SearchWindowView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            SearchField(
                text: $state.query,
                placeholder: state.placeholder,
                onSubmit: state.activate
            )
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            .onChange(of: state.query) { _, new in
                state.onQueryChange(new)
            }

            Divider()

            // Section 1: search results (file/app)
            // The "SEARCH" label makes it clear this is the file
            // and app list, distinct from the AI section below.
            searchSection

            // Section 2: AI reply (only when active)
            // The "AI" badge + clear section header tells the
            // user "this is the LLM talking, not a file match."
            if state.llmError != nil || state.llmReply != nil || state.isLLMBusy {
                Divider()
                    .background(Color.secondary.opacity(0.3))
                llmSection
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.1))
        )
    }

    // MARK: - Search results section

    @ViewBuilder
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header — pinned at the top of the result
            // list. Tiny uppercase label so it doesn't compete
            // with the actual result text, but is always
            // visible so the user knows what they're looking at.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                Text("SEARCH")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                if state.isLoading && !state.isLLMBusy {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if state.results.isEmpty && !state.isLoading {
                VStack {
                    Spacer()
                    Text(state.emptyMessage)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResultListView(
                    results: $state.results,
                    selection: $state.selection,
                    onActivate: { _ in await state.activate() }
                )
                .frame(maxHeight: 200)
            }
        }
    }

    // MARK: - LLM section

    @ViewBuilder
    private var llmSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header — clearly marks the AI section
            // with a colored badge. Uses a different icon and
            // a stronger tint than the search header so the
            // user can tell at a glance which section is which.
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                Text("AI REPLY")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                if state.isLLMBusy {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                }
            }
            .foregroundStyle(.purple)  // distinct from .secondary
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            LLMReplyView(state: state)
                .frame(maxHeight: 220)
        }
        .background(Color.purple.opacity(0.04))  // subtle purple wash
    }
}

/// Renders the LLM's reply (or "thinking…" indicator or an
/// error message) under the AI section. Plain Text with
/// monospaced font for now — Phase 4.1.8.1 can switch to
/// AttributedString for markdown rendering if the LLM emits
/// markdown (Ollama models often do).
private struct LLMReplyView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 6) {
                if let err = state.llmError, !err.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        // Phase 4.2.6: show a "Start Ollama"
                        // button for the not-running variants.
                        // The user can relaunch the Ollama.app
                        // with a single click — we don't
                        // auto-restart it (P2 architecture: Ollama
                        // is an external dependency, not under our
                        // control).
                        if let kind = state.llmErrorKind, Self.shouldShowStartOllamaButton(kind) {
                            Button {
                                Self.startOllama()
                            } label: {
                                Label("Start Ollama", systemImage: "play.circle")
                                    .font(.callout)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                } else if let reply = state.llmReply, !reply.isEmpty {
                    // Phase 4.3.2: if the LLM used tools, show
                    // the tool trace above the final answer.
                    // Each entry is "🔧 tool_name: summary"
                    // produced by AppState.runLLMAsk from the
                    // AskWithToolsResult.toolCalls list.
                    if !state.toolTrace.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(state.toolTrace, id: \.self) { entry in
                                Text(entry)
                                    .font(.caption)
                                    .foregroundStyle(.purple.opacity(0.85))
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    // Streaming: llmReply grows chunk-by-chunk as the
                    // LLM produces tokens. ScrollViewReader lets us
                    // auto-scroll to the bottom so the user always
                    // sees the latest text.
                    // Phase 4.4: file paths the LLM mentioned
                    // in its reply (e.g. "/Users/me/foo.md").
                    // Show each as a clickable button so the
                    // user can open it without copy-paste or
                    // navigating the file system.
                    if !state.llmReplyPaths.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Files mentioned:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(Array(state.llmReplyPaths.enumerated()), id: \.offset) { _, url in
                                Button {
                                    state.openLLMReplyPath(url)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.text")
                                            .font(.caption)
                                        Text(url.lastPathComponent)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help(url.path)
                            }
                        }
                        .padding(.top, 4)
                    }
                    // Phase 4.4: when a tool is running, show
                    // a "🔧 using X..." indicator above the
                    // (currently empty) reply. The LLM reply
                    // text appears below once the loop
                    // completes.
                    if let tool = state.currentToolName {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                            Text("🔧 using \(tool)…")
                                .font(.caption)
                                .foregroundStyle(.purple)
                        }
                        .padding(.bottom, 4)
                    }
                    Text(reply)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                } else if state.isLLMBusy {
                    Label("Thinking…", systemImage: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// True when the error kind is one that can be resolved
    /// by relaunching Ollama.app. Other kinds (timeout, bad
    /// response, etc.) need different fixes.
    private static func shouldShowStartOllamaButton(_ kind: LLMErrorKind) -> Bool {
        switch kind {
        case .ollamaNotRunning, .idleExit, .userQuit:
            return true
        case .ollamaCrashed, .timeout, .badResponse, .other:
            return false
        }
    }

    /// Launch Ollama.app via the system `open` command. We
    /// use Process rather than NSWorkspace.shared.open so we
    /// don't accidentally bring it to the foreground (the
    /// user might be in the middle of typing in our panel —
    /// we want the relaunch to be silent, in the background).
    private static func startOllama() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-g", "-a", "Ollama"]
        // -g = don't bring to foreground (background launch)
        do {
            try task.run()
        } catch {
            // If the launch fails (e.g. Ollama.app not
            // installed), fall back to opening the Ollama
            // homepage in the user's browser so they can
            // download it. The URL is hardcoded because
            // there's no API for "open ollama's website" on
            // macOS.
            if let url = URL(string: "https://ollama.com/download") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
