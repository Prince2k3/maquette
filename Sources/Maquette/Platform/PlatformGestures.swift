import Foundation
import SwiftUI

/// Platform-specific gesture adapters that translate native gestures into diorama intents.
///
/// Each platform maps its native gesture vocabulary to the shared `DioramaGestureType` system:
///
/// | Platform | Rotate | Zoom | Pan |
/// |----------|--------|------|-----|
/// | visionOS | Pinch-drag | Pinch-spread | Two-hand drag |
/// | iOS      | One-finger drag | Pinch | Two-finger drag |
/// | macOS    | Click+drag | Scroll wheel | Right-click drag |
public enum PlatformGestures {
    // Platform gesture adapters are implemented directly in the platform view files
    // (VisionOSDioramaView, IOSDioramaView, MacOSDioramaView) as SwiftUI gesture modifiers.
    //
    // This file serves as documentation and a home for any shared gesture utility functions.

    /// Clamps a value to a range.
    static func clamp<T: Comparable>(_ value: T, min minVal: T, max maxVal: T) -> T {
        min(max(value, minVal), maxVal)
    }

    /// Converts a 2D drag translation to rotation deltas suitable for the camera controller.
    static func rotationDelta(from translation: CGSize, sensitivity: Float = 0.005) -> (deltaX: Float, deltaY: Float) {
        (Float(translation.width) * sensitivity, Float(translation.height) * sensitivity)
    }
}
