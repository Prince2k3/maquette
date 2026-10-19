import SwiftUI

/// How much additional ground is kept ready outside a chunk's outline.
///
/// This is a prefetch policy, not a geographic pan limit. Ground continues streaming as you pan.
public struct DioramaLoadingPolicy: Sendable, Equatable {
    let margin: Float?

    /// Provisions a margin when pan interaction is enabled, respecting a legacy style's margin.
    public static let automatic = Self(margin: nil)

    /// Keeps a fraction of the chunk's extent loaded beyond its outline.
    ///
    /// Zero disables ground panning and its prefetch margin. Negative or nonfinite values become
    /// zero. Use interaction modes to control permission independently of this loading policy.
    public static func prefetchMargin(_ fraction: Float) -> Self {
        Self(margin: fraction.isFinite ? max(0, fraction) : 0)
    }
}

extension DioramaStyle {
    func resolving(_ policy: DioramaLoadingPolicy, interactionModes: DioramaInteractionModes) -> Self {
        var resolved = self
        resolved.panRange = policy.margin ?? (panRange > 0 ? panRange : (interactionModes.contains(.pan) ? 0.5 : 0))
        return resolved
    }
}

extension View {
    /// Sets the exact outline for dioramas in this hierarchy.
    /// The nearest modifier takes precedence over the initializer's shape.
    public func dioramaShape(_ shape: DioramaShape) -> some View {
        environment(\.dioramaShapeOverride, shape)
    }

    /// Sets the physical span in diorama meters for dioramas in this hierarchy.
    /// The nearest modifier takes precedence over the initializer's physical size.
    public func dioramaPhysicalSize(_ meters: Float) -> some View {
        environment(\.dioramaPhysicalSizeOverride, meters)
    }

    /// Sets ground prefetch independently of terrain appearance.
    /// With the default automatic policy, enabling pan provisions a sensible margin automatically.
    public func dioramaLoadingPolicy(_ policy: DioramaLoadingPolicy) -> some View {
        environment(\.dioramaLoadingPolicy, policy)
    }
}

extension EnvironmentValues {
    @Entry var dioramaShapeOverride: DioramaShape? = nil
    @Entry var dioramaPhysicalSizeOverride: Float? = nil
    @Entry var dioramaLoadingPolicy: DioramaLoadingPolicy = .automatic
}
