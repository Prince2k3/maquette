import Foundation
import SwiftUI

/// Describes the types of interactive gestures supported by the diorama.
public enum DioramaGestureType: Sendable, Hashable {
    /// Rotate the diorama (orbit camera or rotate entity).
    case rotate
    /// Zoom in/out on the diorama.
    case zoom
    /// Pan/translate the diorama view.
    case pan
}

/// View modifier that configures which gestures are enabled on a diorama view.
public struct DioramaGesturesModifier: ViewModifier {
    let enabledGestures: Set<DioramaGestureType>

    public func body(content: Content) -> some View {
        content
            .environment(\.enabledDioramaGestures, enabledGestures)
    }
}

extension View {
    /// Configures which interactive gestures are enabled on this diorama.
    ///
    /// ```swift
    /// DioramaView(configuration: config)
    ///     .dioramaGestures([.rotate, .zoom, .pan])
    /// ```
    public func dioramaGestures(_ gestures: Set<DioramaGestureType>) -> some View {
        modifier(DioramaGesturesModifier(enabledGestures: gestures))
    }
}

// MARK: - Environment Key

extension EnvironmentValues {
    @Entry var enabledDioramaGestures: Set<DioramaGestureType> = [.rotate, .zoom, .pan]
}

// MARK: - Conditional Gesture Helper

extension View {
    /// Applies the gesture only when the condition is true.
    @ViewBuilder
    func gestureIf<G: Gesture>(_ condition: Bool, _ gesture: G) -> some View {
        if condition {
            self.gesture(gesture)
        } else {
            self
        }
    }
}
