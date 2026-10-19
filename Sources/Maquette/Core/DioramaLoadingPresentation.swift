import SwiftUI

/// Loading information and a retry action for an application's custom diorama overlay.
@MainActor
public struct DioramaLoadingContext {
    /// The current loading phase.
    public let state: DioramaLoadingState
    /// Streaming progress for photorealistic content, or `nil` for raster terrain.
    public let streamingProgress: DioramaStreamingProgress?
    let retryAction: (() -> Void)?

    /// Retries a failed load. Other loading phases ignore the request.
    public func retry() {
        guard case .failed = state else { return }
        retryAction?()
    }
}

extension View {
    /// Replaces the built-in loading, error, and streaming UI for dioramas in this hierarchy.
    ///
    /// Return an empty view for phases your application does not need to display. Attribution is
    /// presented separately and is unaffected by this modifier.
    public func dioramaLoadingOverlay<Overlay: View>(
        @ViewBuilder content: @escaping @MainActor (DioramaLoadingContext) -> Overlay
    ) -> some View {
        environment(\.dioramaLoadingPresentation, DioramaLoadingPresentation { AnyView(content($0)) })
    }

    /// Hides loading, error, and streaming overlays, including a custom loading overlay.
    /// Use ``onDioramaLoadingChange(_:)`` to reflect loading elsewhere in the application.
    public func dioramaLoadingOverlayHidden(_ hidden: Bool = true) -> some View {
        environment(\.dioramaLoadingOverlayHidden, hidden)
    }
}

struct DioramaLoadingPresentation {
    let content: @MainActor (DioramaLoadingContext) -> AnyView
}

extension EnvironmentValues {
    @Entry var dioramaLoadingPresentation: DioramaLoadingPresentation? = nil
    @Entry var dioramaLoadingOverlayHidden = false
}
