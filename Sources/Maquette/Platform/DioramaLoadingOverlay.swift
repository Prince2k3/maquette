import SwiftUI

/// Shared overlay that displays loading and error states for the diorama.
///
/// Used by all platform views (iOS, macOS, visionOS) to provide consistent
/// feedback during tile fetching and mesh generation.
struct DioramaLoadingOverlay: ViewModifier {
    let loadingState: DioramaLoadingState
    /// Streaming state for presentations that keep arriving after they are displayable.
    let streamingProgress: DioramaStreamingProgress?
    let onRetry: (() -> Void)?
    @Environment(\.dioramaLoadingPresentation) private var customPresentation
    @Environment(\.dioramaLoadingOverlayHidden) private var isHidden

    func body(content: Content) -> some View {
        content
            .overlay {
                if !isHidden {
                    if let customPresentation {
                        customPresentation.content(DioramaLoadingContext(
                            state: loadingState, streamingProgress: streamingProgress, retryAction: onRetry
                        ))
                    } else {
                        primaryOverlay
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if !isHidden, customPresentation == nil { streamingIndicator }
            }
    }

    @ViewBuilder
    private var primaryOverlay: some View {
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

    /// A quiet corner indicator for content that arrives after the diorama is displayable.
    ///
    /// Deliberately not the blocking spinner above. A streaming model is worth looking at from the
    /// first tile and visibly improves for as long as this is on screen, so covering it would hide
    /// the thing the indicator is reporting on.
    @ViewBuilder
    private var streamingIndicator: some View {
        if case .loaded = loadingState, let progress = streamingProgress, progress.isStreaming {
            HStack(spacing: 8) {
                // Linear rather than circular: iOS's circular style has no determinate form, so a
                // fraction handed to it is silently thrown away and spins instead.
                ProgressView(value: progress.fractionComplete)
                    .progressViewStyle(.linear)
                    .frame(width: 56)
                Text("Streaming detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(12)
            .transition(.opacity)
            .accessibilityIdentifier("diorama-streaming-indicator")
            .accessibilityLabel("Streaming detail, \(Int(progress.fractionComplete * 100)) percent")
        }
    }
}

extension View {
    func dioramaLoadingOverlay(
        state: DioramaLoadingState,
        streamingProgress: DioramaStreamingProgress? = nil,
        onRetry: (() -> Void)? = nil
    ) -> some View {
        modifier(DioramaLoadingOverlay(
            loadingState: state,
            streamingProgress: streamingProgress,
            onRetry: onRetry
        ))
    }
}
