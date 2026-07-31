import Foundation
import SwiftUI

extension View {
    /// Places dioramas in this hierarchy on a real surface through the device camera.
    ///
    /// While the binding is `true`, an iOS or iPadOS `DioramaView` switches its `RealityView` to
    /// the spatial-tracking camera — the room appears behind the model — and re-parents the
    /// diorama to a horizontal-plane anchor, so it lands on the first table-like surface the
    /// device finds at its true ``DioramaView`` `physicalSize` in real meters. Setting the binding
    /// back to `false` returns to the virtual orbit camera.
    ///
    /// iOS and iPadOS only: macOS has no camera to track with, and a visionOS diorama is already
    /// spatial — its volume *is* the placement. On both, the binding is accepted and ignored.
    ///
    /// ```swift
    /// @State private var isPlacingInAR = false
    ///
    /// DioramaView(region: region)
    ///     .dioramaARPlacement($isPlacingInAR)
    /// ```
    public func dioramaARPlacement(_ isActive: Binding<Bool>) -> some View {
        environment(\.dioramaARPlacement, isActive)
    }
}

extension EnvironmentValues {
    @Entry var dioramaARPlacement: Binding<Bool>? = nil
}
