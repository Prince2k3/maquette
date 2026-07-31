import Foundation
import SwiftUI

/// The gesture vocabulary the platform views route against.
///
/// The public face of this is ``DioramaInteractionModes`` on `DioramaView`'s initializer, which is
/// where MapKit puts the equivalent; this internal set is what the routing code consumes.
///
/// ## How they map to input
///
/// On iOS the split follows what a map does: **one finger** slides the terrain beneath the chunk's
/// outline, and **two fingers** orbit the camera and pinch to zoom. On macOS a pointer has no
/// second finger, so **drag** slides the terrain and **option-drag** orbits, with pinch or scroll
/// to zoom. On visionOS a drag slides and a pinch zooms.
///
/// Terrain sliding requires a chunk that can pan, which means a style with a non-zero `panRange`.
/// Without one, a single drag orbits instead, so a fixed diorama behaves as it always has.
enum DioramaGestureType: Sendable, Hashable {
    /// Orbit the camera around the diorama.
    case rotate
    /// Zoom in/out on the diorama.
    case zoom
    /// Slide the terrain beneath the chunk's outline.
    case pan
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
