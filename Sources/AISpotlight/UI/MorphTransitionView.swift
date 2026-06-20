import SwiftUI

// MARK: - MorphTransitionView

/// A view that handles the Panel → App morph transition.
///
/// **How it works:**
/// 1. The panel takes a snapshot of its current state.
/// 2. A `TransitionLayer` overlay fades in over the snapshot.
/// 3. The panel smoothly animates its geometry to the app frame.
/// 4. Once the animation completes, the app content replaces the overlay.
///
/// **Usage:**
/// ```swift
/// MorphTransitionView(
///     isCompact: $isCompact,
///     compactContent: { PanelView(...) },
///     expandedContent: { AppView(...) }
/// )
/// ```
struct MorphTransitionView<Compact: View, Expanded: View>: View {
    @Binding var isCompact: Bool
    let compactContent: Compact
    let expandedContent: Expanded

    @State private var morphProgress: CGFloat = 0
    @State private var isAnimating = false

    private let animationDuration: TimeInterval = 0.4

    var body: some View {
        ZStack {
            // Always render the compact panel
            compactContent
                .opacity(isAnimating ? 1 - morphProgress : (isCompact ? 1 : 0))
                .scaleEffect(isAnimating ? 1 - morphProgress * 0.05 : 1)

            // Expanded content (fades in during morph)
            expandedContent
                .opacity(isAnimating ? morphProgress : (isCompact ? 0 : 1))
                .scaleEffect(isAnimating ? 0.95 + morphProgress * 0.05 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: isAnimating ? 16 * (1 - morphProgress) : (isCompact ? 16 : 0)))
        .onChange(of: isCompact) { _, newValue in
            guard !isAnimating else { return }
            triggerMorph(toCompact: newValue)
        }
    }

    private func triggerMorph(toCompact: Bool) {
        isAnimating = true
        morphProgress = toCompact ? 1 : 0

        withAnimation(.spring(response: animationDuration, dampingFraction: 0.85)) {
            morphProgress = toCompact ? 0 : 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.05) {
            isAnimating = false
        }
    }
}

// MARK: - Preview helper

extension MorphTransitionView {
    /// Create a morph transition with compact and expanded content.
    init(
        isCompact: Binding<Bool>,
        @ViewBuilder compact: () -> Compact,
        @ViewBuilder expanded: () -> Expanded
    ) {
        self._isCompact = isCompact
        self.compactContent = compact()
        self.expandedContent = expanded()
    }
}
