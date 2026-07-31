import Foundation

/// The interactions a ``DioramaView`` responds to. The parallel of MapKit's `MapInteractionModes`.
public struct DioramaInteractionModes: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Orbiting the camera around the diorama (and steering the globe).
    public static let rotate = DioramaInteractionModes(rawValue: 1 << 0)
    /// Zooming the ground — and, past its limit, the globe handoff.
    public static let zoom = DioramaInteractionModes(rawValue: 1 << 1)
    /// Sliding the terrain beneath the chunk's fixed outline.
    public static let pan = DioramaInteractionModes(rawValue: 1 << 2)

    /// Everything.
    public static let all: DioramaInteractionModes = [.rotate, .zoom, .pan]

    /// The gesture-type set the platform views route against.
    var gestureTypes: Set<DioramaGestureType> {
        var types: Set<DioramaGestureType> = []
        if contains(.rotate) { types.insert(.rotate) }
        if contains(.zoom) { types.insert(.zoom) }
        if contains(.pan) { types.insert(.pan) }
        return types
    }
}
