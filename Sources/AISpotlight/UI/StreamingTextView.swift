import SwiftUI

// MARK: - Cursor Style

enum CursorStyle: Equatable {
    case block   // ▌
    case line    // |
    case none
}

// MARK: - Streaming Typewriter Text View

/// Displays text with a character-by-character fade-in animation,
/// mimicking ChatGPT/Claude-style streaming output.
struct StreamingTextView: View {
    var text: String
    var isStreaming: Bool
    var typingSpeed: TimeInterval = 0.04
    var cursorStyle: CursorStyle = .block
    var font: Font = .system(size: 13, design: .monospaced)
    var textColor: Color = .primary.opacity(0.9)

    @State private var displayedCount: Int = 0
    @State private var cursorVisible: Bool = true
    @State private var batchTimer: Timer?

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            // Revealed text — each batch has a small fade-in
            let revealed = String(text.prefix(displayedCount))
            if !revealed.isEmpty {
                Text(revealed)
                    .font(font)
                    .foregroundStyle(textColor)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Cursor
            if isStreaming && displayedCount < text.count {
                cursorView
                    .padding(.leading, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.12), value: displayedCount)
        .onChange(of: text) { _, newText in
            if newText.count < displayedCount || text.isEmpty {
                displayedCount = 0
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming {
                startTyping()
            } else {
                // Reveal all remaining text when streaming ends
                displayedCount = text.count
                stopTimer()
            }
        }
        .onAppear {
            if isStreaming {
                startTyping()
            } else {
                displayedCount = text.count
            }
        }
        .onDisappear {
            stopTimer()
        }
    }

    // MARK: - Cursor

    @ViewBuilder
    private var cursorView: some View {
        switch cursorStyle {
        case .block:
            Text(cursorVisible ? "▌" : " ")
                .font(font)
                .foregroundStyle(Color.accentColor)
        case .line:
            Text(cursorVisible ? "|" : " ")
                .font(font)
                .foregroundStyle(Color.accentColor)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Typing Timer

    private func startTyping() {
        stopTimer()

        // If we already have some content, we may be resuming
        if displayedCount == 0 && !text.isEmpty {
            // Show first batch immediately
            let batchSize = min(10, text.count)
            displayedCount = batchSize
        }

        batchTimer = Timer.scheduledTimer(withTimeInterval: typingSpeed * 10, repeats: true) { _ in
            DispatchQueue.main.async {
                guard self.isStreaming else { return }
                let remaining = self.text.count - self.displayedCount
                if remaining <= 0 {
                    self.stopTimer()
                    return
                }
                let batch = min(10, remaining)
                self.displayedCount += batch
            }
        }

        // Cursor blink timer (independent from typing)
        Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { timer in
            DispatchQueue.main.async {
                guard self.isStreaming else {
                    timer.invalidate()
                    return
                }
                self.cursorVisible.toggle()
            }
        }
    }

    private func stopTimer() {
        batchTimer?.invalidate()
        batchTimer = nil
        cursorVisible = false
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        StreamingTextView(
            text: "Hello! I'm AI Spotlight. I can search your files, answer questions, and help you get things done faster.",
            isStreaming: true,
            cursorStyle: .block
        )
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)

        StreamingTextView(
            text: "This is a completed response with no cursor.",
            isStreaming: false,
            cursorStyle: .none
        )
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
    .padding()
    .frame(width: 400)
}
