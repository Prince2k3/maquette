import SwiftUI

/// Shared overlay that displays loading and error states for the diorama.
///
/// Used by all platform views (iOS, macOS, visionOS) to provide consistent
/// feedback during tile fetching and mesh generation.
struct DioramaLoadingOverlay: ViewModifier {
    let loadingState: DioramaLoadingState

    func body(content: Content) -> some View {
        content.overlay {
            switch loadingState {
            case .loading:
                ProgressView("Loading terrain...")
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            case .failed(let error):
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("Failed to load diorama")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            case .idle, .loaded:
                EmptyView()
            }
        }
    }
}

extension View {
    func dioramaLoadingOverlay(state: DioramaLoadingState) -> some View {
        modifier(DioramaLoadingOverlay(loadingState: state))
    }
}
