import SwiftUI

/// Shared overlay that displays loading and error states for the diorama.
///
/// Used by all platform views (iOS, macOS, visionOS) to provide consistent
/// feedback during tile fetching and mesh generation.
struct DioramaLoadingOverlay: ViewModifier {
    let loadingState: DioramaLoadingState
    let onRetry: (() -> Void)?

    func body(content: Content) -> some View {
        content.overlay {
            switch loadingState {
            case .loading:
                ProgressView {
                    Text("Loading terrain...")
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            case .failed(let error):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("Failed to load diorama")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let onRetry {
                        Button {
                            onRetry()
                        } label: {
                            Text("Retry")
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                    }
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
    func dioramaLoadingOverlay(
        state: DioramaLoadingState,
        onRetry: (() -> Void)? = nil
    ) -> some View {
        modifier(DioramaLoadingOverlay(loadingState: state, onRetry: onRetry))
    }
}
