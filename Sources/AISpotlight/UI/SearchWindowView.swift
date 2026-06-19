import SwiftUI
import AISpotlightKit

// MARK: - Premium Minimalist Search Window

struct SearchWindowView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            // ── Apple Intelligence Bezel Glow ──
            // Only active when AI is thinking or has a reply
            if state.isLLMBusy || state.llmReply != nil {
                BezelGlowView(
                    isActive: true,
                    cornerRadius: 16
                )
                .allowsHitTesting(false)
                .transition(.opacity.animation(.easeInOut(duration: 0.6)))
            }

            // ── Main Panel Content ──
            VStack(spacing: 0) {
                SearchField(
                    text: $state.query,
                    placeholder: state.placeholder,
                    onSubmit: state.activate
                )
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .onChange(of: state.query) { _, new in
                    state.onQueryChange(new)
                }

                dividerLine

                searchSection
                    .transition(.opacity.combined(with: .move(edge: .top)))

                if state.llmError != nil || state.llmReply != nil || state.isLLMBusy {
                    dividerLine
                    llmSection
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)).animation(.spring(response: 0.38, dampingFraction: 0.85)),
                                removal: .opacity.animation(.easeOut(duration: 0.2))
                            )
                        )
                }
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.12), .white.opacity(0.04), .white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
        }
        .shadow(color: .black.opacity(0.18), radius: 30, x: 0, y: 8)
        .sheet(isPresented: .init(
            get: { state.pendingConsent != nil },
            set: { if !$0 { state.pendingConsent = nil } }
        )) {
            consentDialog
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: state.results.isEmpty)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: state.isLLMBusy)
        .animation(.easeInOut(duration: 0.6), value: state.llmReply != nil)
    }

    // MARK: - Divider

    private var dividerLine: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [.white.opacity(0.05), .white.opacity(0.1), .white.opacity(0.05)],
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(height: 1)
    }

    // MARK: - Search Results Section

    @ViewBuilder
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                icon: "magnifyingglass",
                title: "Search",
                accentColor: .secondary,
                isLoading: state.isLoading && !state.isLLMBusy
            )

            if state.results.isEmpty && !state.isLoading {
                emptyStateView(message: state.emptyMessage)
                    .transition(.opacity)
            } else {
                ResultListView(
                    results: $state.results,
                    selection: $state.selection,
                    onActivate: { _ in await state.activate() }
                )
                .frame(maxHeight: 220)
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
    }

    // MARK: - LLM Section

    @ViewBuilder
    private var llmSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                icon: "sparkles",
                title: "AI Reply",
                accentColor: .purple,
                isLoading: state.isLLMBusy
            )

            LLMReplyView(state: state)
                .frame(maxHeight: 260)
        }
        .background(
            LinearGradient(
                colors: [Color.purple.opacity(0.03), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
        )
    }

    // MARK: - Reusable Section Header

    @ViewBuilder
    private func sectionHeader(icon: String, title: String, accentColor: Color, isLoading: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(1.2)
            if isLoading {
                ProgressView()
                    .scaleEffect(0.45)
                    .frame(width: 8, height: 8)
            }
        }
        .foregroundStyle(accentColor.opacity(0.7))
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Empty State

    @ViewBuilder
    private func emptyStateView(message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
            Text(message)
                .foregroundStyle(.tertiary)
                .font(.system(size: 13))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Consent Dialog

    private var consentDialog: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 32))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, .orange.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom)
                )

            Text("Allow Tool?")
                .font(.system(size: 16, weight: .semibold))

            if let pc = state.pendingConsent {
                VStack(alignment: .leading, spacing: 10) {
                    detailRow(label: "Tool", value: pc.tool, monospaced: true)
                    detailRow(label: "Args", value: pc.args, monospaced: true)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.gray.opacity(0.06))
                )
            }

            HStack(spacing: 12) {
                Button("Deny") {
                    state.respondToConsent(approved: false)
                }
                .buttonStyle(.bordered)
                .tint(.red.opacity(0.8))

                Button("Allow") {
                    state.respondToConsent(approved: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
        }
        .padding(28)
        .frame(minWidth: 340)
    }

    @ViewBuilder
    private func detailRow(label: String, value: String, monospaced: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(value)
                .font(monospaced ? .system(size: 11).monospaced() : .system(size: 11))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - LLM Reply View (Premium)

private struct LLMReplyView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                if let err = state.llmError, !err.isEmpty {
                    errorView(err)
                } else if let reply = state.llmReply, !reply.isEmpty {
                    replyContentView(reply: reply)
                } else if state.isLLMBusy {
                    thinkingIndicator
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Error View

    private func errorView(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.red.opacity(0.7))
                Text(err)
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let kind = state.llmErrorKind, Self.shouldShowStartOllamaButton(kind) {
                Button {
                    Self.startOllama()
                } label: {
                    Label("Start Ollama", systemImage: "play.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.red.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.red.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Reply Content (with typewriter streaming)

    @ViewBuilder
    private func replyContentView(reply: String) -> some View {
        // Tool Trace
        if !state.toolTrace.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(state.toolTrace, id: \.self) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.2")
                            .font(.system(size: 9))
                            .foregroundStyle(.purple.opacity(0.5))
                        Text(entry)
                            .font(.system(size: 11))
                            .foregroundStyle(.purple.opacity(0.75))
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.purple.opacity(0.04))
            )
            .padding(.bottom, 4)
        }

        // Running tool indicator
        if let tool = state.currentToolName {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                HStack(spacing: 4) {
                    Image(systemName: "hammer")
                        .font(.system(size: 10))
                    Text("Using \(tool)…")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.purple.opacity(0.8))
            }
            .padding(.bottom, 6)
        }

        // ═══ Streaming Typewriter Text ═══
        StreamingTextView(
            text: reply,
            isStreaming: state.isLLMBusy,
            cursorStyle: .block,
            font: .system(size: 13, design: .monospaced),
            textColor: .primary.opacity(0.9)
        )
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.5)
                )
        )

        // LLM-reply file paths
        if !state.llmReplyPaths.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Files Mentioned")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)

                ForEach(Array(state.llmReplyPaths.enumerated()), id: \.offset) { _, url in
                    Button {
                        state.openLLMReplyPath(url)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 10))
                            Text(url.lastPathComponent)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.03))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(url.path)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Thinking Indicator

    private var thinkingIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Thinking…")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Static Helpers

    private static func shouldShowStartOllamaButton(_ kind: LLMErrorKind) -> Bool {
        switch kind {
        case .ollamaNotRunning, .idleExit, .userQuit: return true
        case .ollamaCrashed, .timeout, .badResponse, .other: return false
        }
    }

    private static func startOllama() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-g", "-a", "Ollama"]
        do {
            try task.run()
        } catch {
            if let url = URL(string: "https://ollama.com/download") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
