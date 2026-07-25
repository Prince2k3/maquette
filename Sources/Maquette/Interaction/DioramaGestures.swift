import Foundation
import SwiftUI

/// Describes the types of interactive gestures supported by the diorama.
///
/// ## How they map to input
///
/// On iOS the split follows what a map does: **one finger** slides the terrain beneath the chunk's
/// outline, and **two fingers** orbit the camera and pinch to zoom. On macOS a pointer has no
/// second finger, so **drag** slides the terrain and **option-drag** orbits, with scroll to zoom.
///
/// Terrain sliding requires a chunk that can pan, which means a configuration with a non-zero
/// `panRange`. Without one, a single drag orbits instead, so a fixed diorama behaves as it always
/// has.
public enum DioramaGestureType: Sendable, Hashable {
    /// Orbit the camera around the diorama.
    case rotate
    /// Zoom in/out on the diorama.
    case zoom
    /// Slide the terrain beneath the chunk's outline.
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

    /// Applies the gesture at high priority only when the condition is true.
    @ViewBuilder
    func highPriorityGestureIf<G: Gesture>(_ condition: Bool, _ gesture: G) -> some View {
        if condition {
            self.highPriorityGesture(gesture)
        } else {
            self
        }
    }
}
