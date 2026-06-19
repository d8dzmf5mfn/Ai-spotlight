import SwiftUI
import AISpotlightKit

struct ResultRowView: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // ── Selected indicator bar ──
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 2.5)
                    .padding(.vertical, 4)
                    .transition(.scale.combined(with: .opacity))
            }

            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                    .frame(width: 32, height: 32)
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.8))
            }

            // Title + Subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)
                if let s = result.subtitle {
                    Text(s)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Open hint
            if isSelected {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 9, weight: .bold))
                    Text("Open")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.05))
                )
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .padding(.horizontal, 4)
        .animation(.spring(response: 0.2, dampingFraction: 0.9), value: isSelected)
    }

    private var iconName: String {
        switch result.kind {
        case .file:
            return result.url.pathExtension.lowercased() == "pdf" ? "doc.text.fill" : "doc"
        case .folder: return "folder"
        case .app: return "app.badge.checkmark"
        case .command: return result.iconSystemName
        }
    }
}
