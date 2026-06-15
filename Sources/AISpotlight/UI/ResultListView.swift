import SwiftUI
import AISpotlightKit

struct ResultListView: View {
    @Binding var results: [SearchResult]
    @Binding var selection: Int?
    let onActivate: (SearchResult) async -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { idx, r in
                        ResultRowView(result: r, isSelected: selection == idx)
                            .id(idx)
                            .onTapGesture { Task { await onActivate(r) } }
                    }
                }
            }
            .onChange(of: selection) { _, new in
                if let n = new { proxy.scrollTo(n, anchor: .center) }
            }
        }
    }
}
