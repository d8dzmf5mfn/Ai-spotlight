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
                    onActivate: { _ in state.activate() }
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
                if let err = state.llmError {
                    Label("LLM error: \(err)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                } else if let reply = state.llmReply, !reply.isEmpty {
                    // Streaming: llmReply grows chunk-by-chunk as the
                    // LLM produces tokens. ScrollViewReader lets us
                    // auto-scroll to the bottom so the user always
                    // sees the latest text.
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
}
