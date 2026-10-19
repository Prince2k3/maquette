import Maquette
import SwiftUI
import Testing

@Suite("Custom loading public API")
@MainActor
struct DioramaLoadingAPITests {
    @Test("Custom loading views can show errors and use the scoped retry action")
    func customOverlay() {
        let region = DioramaRegion(center: Coordinate(latitude: 36, longitude: -112), radius: 1500)
        _ = DioramaView(region: region)
            .dioramaLoadingOverlay { context in
                switch context.state {
                case .loading:
                    ProgressView("Preparing diorama")
                case .failed:
                    Button("Try again") { context.retry() }
                case .loaded:
                    if let progress = context.streamingProgress, progress.isStreaming {
                        ProgressView(value: progress.fractionComplete)
                    }
                case .idle:
                    EmptyView()
                }
            }
        _ = DioramaView(region: region).dioramaLoadingOverlayHidden()
    }
}
