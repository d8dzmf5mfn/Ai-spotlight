import SwiftUI

// MARK: - Apple Intelligence Style Bezel Glow
//
// Three-layer edge glow inspired by Apple Intelligence Siri UI.
// Colors from research document: Lavender, Pink, Periwinkle Blue,
// Bright Purple, Coral Red, Peach Orange, Bright Orchid.

// MARK: - Color Palette

fileprivate let glowColors: [Color] = [
    Color(red: 0.737, green: 0.510, blue: 0.953),  // #BC82F3 Lavender
    Color(red: 0.961, green: 0.725, blue: 0.918),  // #F5B9EA Light Pink
    Color(red: 0.553, green: 0.624, blue: 1.000),  // #8D9FFF Periwinkle Blue
    Color(red: 0.667, green: 0.431, blue: 0.933),  // #AA6EEE Bright Purple
    Color(red: 1.000, green: 0.404, blue: 0.471),  // #FF6778 Coral Red
    Color(red: 1.000, green: 0.729, blue: 0.443),  // #FFBA71 Peach Orange
    Color(red: 0.776, green: 0.525, blue: 1.000),  // #C686FF Bright Orchid
]

// MARK: - BezelGlowView

struct BezelGlowView: View {
    var isActive: Bool = true
    var cornerRadius: CGFloat = 16
    var cycleDuration: Double = 3.6
    var layerPhaseOffset: Double = 0.3

    var body: some View {
        if isActive {
            TimelineView(.periodic(from: .now, by: 1/30)) { timeline in
                GeometryReader { geo in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let progress = fmod(t, cycleDuration) / cycleDuration

                    ZStack {
                        // Layer 1: Sharp Base — clear outline, no blur
                        glowStroke(
                            width: 1.5,
                            blur: 0,
                            progress: progress,
                            phase: 0
                        )
                        // Layer 2: Middle Rich — moderate blur
                        glowStroke(
                            width: 4,
                            blur: 8,
                            progress: progress,
                            phase: layerPhaseOffset / cycleDuration
                        )
                        // Layer 3: Outer Halo — heavy blur, wide spread
                        glowStroke(
                            width: 12,
                            blur: 24,
                            progress: progress,
                            phase: layerPhaseOffset * 2 / cycleDuration
                        )
                    }
                }
            }
        }
    }

    // MARK: - Single Glow Stroke

    private func glowStroke(width: CGFloat, blur: CGFloat, progress: Double, phase: Double) -> some View {
        let p = fmod(progress + phase, 1.0)
        let gradient = animatedGradient(progress: p)

        return RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(gradient, lineWidth: width)
            .blur(radius: blur)
    }

    // MARK: - Animated Gradient

    private func animatedGradient(progress: Double) -> some ShapeStyle {
        // Generate random location vectors, sorted ascending for smooth distribution
        let count = glowColors.count
        var locations: [CGFloat] = (0..<count).map { _ in
            CGFloat.random(in: 0...1)
        }
        locations.sort()
        // Normalize so first is near 0 and last near 1
        if let min = locations.min(), let max = locations.max() {
            let range = max - min
            if range > 0.01 {
                locations = locations.map { ($0 - min) / range }
            } else {
                locations = locations.enumerated().map { CGFloat($0.offset) / CGFloat(count - 1) }
            }
        }

        // Shift colors by progress to create rotation
        let shift = Int(progress * Double(count)) % count
        let shifted = Array(glowColors[shift...] + glowColors[..<shift])

        return LinearGradient(
            colors: shifted,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black
        BezelGlowView(isActive: true, cornerRadius: 16)
            .padding(40)
    }
    .frame(width: 400, height: 300)
}
