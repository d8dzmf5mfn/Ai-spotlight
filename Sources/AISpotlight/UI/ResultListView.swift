import SwiftUI
import AISpotlightKit

struct ResultListView: View {
    @Binding var results: [SearchResult]
    @Binding var selection: Int?
    let onActivate: (SearchResult) async -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { idx, r in
                        ResultRowView(result: r, isSelected: selection == idx)
                            .id(idx)
                            .onTapGesture { Task { await onActivate(r) } }
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)).animation(.spring(response: 0.3, dampingFraction: 0.8).delay(Double(idx) * 0.02)),
                                    removal: .opacity.animation(.easeOut(duration: 0.15))
                                )
                            )
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection) { _, new in
                if let n = new { proxy.scrollTo(n, anchor: .center) }
            }
        }
    }
}
