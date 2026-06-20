import SwiftUI
import AISpotlightKit

/// A state-driven edge glow that wraps the panel content.
///
/// **Design:**
/// - Owns no logic — it reads `AIState.glowIntensity` and renders.
/// - The glow is a radial gradient overlay with animated opacity/scale.
/// - Transitions between states are smooth (spring animation).
///
/// This replaces the previous hardcoded glow logic in `BezelGlowView`.
struct EdgeGlowView<Content: View>: View {
    let intensity: Double
    let content: Content

    @State private var animPhase: Double = 0

    init(intensity: Double, @ViewBuilder content: () -> Content) {
        self.intensity = intensity
        self.content = content()
    }

    var body: some View {
        content
            .overlay(glowOverlay, alignment: .top)
            .overlay(glowOverlay, alignment: .bottom)
    }

    @ViewBuilder
    private var glowOverlay: some View {
        if intensity > 0.01 {
            LinearGradient(
                colors: [
                    .purple.opacity(intensity * 0.3),
                    .blue.opacity(intensity * 0.15),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 40 + intensity * 20)
            .opacity(intensity)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: intensity)
        }
    }
}
