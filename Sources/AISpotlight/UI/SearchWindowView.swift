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

            // Phase 4.1.8: render the LLM reply under the result
            // list. We always reserve some space (rather than
            // appearing/disappearing) so the panel doesn't jump
            // when an ask starts/finishes.
            if state.llmError != nil || state.llmReply != nil || state.isLLMBusy {
                Divider()
                LLMReplyView(state: state)
                    .frame(maxHeight: 220)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.1))
        )
    }
}

/// Renders the LLM's reply (or "thinking…" indicator or an
/// error message) under the result list. Plain Text with
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
