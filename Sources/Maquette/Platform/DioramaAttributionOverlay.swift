import SwiftUI

/// Draws the tile services' required credit line over the diorama.
///
/// Shown whenever the store carries an attribution — which today means the photorealistic
/// pipeline — and deliberately not suppressible: displaying the sources credited by the tiles in
/// view is a condition of using those services at all. Google additionally requires its logo
/// alongside the text; the logo asset cannot ship inside a package that carries no resources, so
/// that half of the obligation is the integrating app's, and is documented on
/// ``GoogleTiles3DProvider``.
struct DioramaAttributionOverlay: ViewModifier {
    let attribution: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if let attribution {
                Text(attribution)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(8)
                    .accessibilityLabel("Map data attribution: \(attribution)")
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Overlays the tile attribution when one is required.
    func dioramaAttribution(_ attribution: String?) -> some View {
        modifier(DioramaAttributionOverlay(attribution: attribution))
    }
}
