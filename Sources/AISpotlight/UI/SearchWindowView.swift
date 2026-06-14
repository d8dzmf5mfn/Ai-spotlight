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
                .frame(maxHeight: 320)
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
