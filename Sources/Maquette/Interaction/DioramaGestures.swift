import Foundation
import SwiftUI

/// Internal intent permissions routed by platform adapters. Public callers use the independent
/// flags on DioramaInteractionModes. The map preset never substitutes a camera action when
/// ground navigation is unavailable; the explicit legacy preset retains earlier drag mapping.
enum DioramaGestureType: Sendable, Hashable {
    /// Orbit the camera around the diorama.
    case rotate
    case heading
    case pitch
    case cameraZoom
    /// Zoom the ground, including globe travel.
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

    /// Applies the gesture alongside any others only when the condition is true.
    ///
    /// Two gestures attached with ``SwiftUI/View/gesture(_:including:)`` compete: the outermost
    /// claims the sequence and the inner one never recognizes. That is fatal on visionOS, where a
    /// drag and a magnify are attached to the same entity and each is driven by a different number
    /// of hands — attached exclusively, whichever is outermost swallows the other's events and one
    /// of pan or zoom silently stops working.
    @ViewBuilder
    func simultaneousGestureIf<G: Gesture>(_ condition: Bool, _ gesture: G) -> some View {
        if condition {
            self.simultaneousGesture(gesture)
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

extension Set where Element == DioramaGestureType {
    var allowsHeading: Bool { contains(.heading) || contains(.rotate) }
    var allowsPitch: Bool { contains(.pitch) || contains(.rotate) }
}
