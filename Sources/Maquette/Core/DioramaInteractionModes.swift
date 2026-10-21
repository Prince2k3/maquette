import Foundation

/// Independent user interaction permissions. Application camera/ground requests remain authoritative.
public struct DioramaInteractionModes: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let heading = Self(rawValue: 1 << 0)
    public static let pitch = Self(rawValue: 1 << 1)
    public static let groundPan = Self(rawValue: 1 << 2)
    public static let groundZoom = Self(rawValue: 1 << 3)
    public static let cameraZoom = Self(rawValue: 1 << 4)
    public static let all: Self = [.heading, .pitch, .groundPan, .groundZoom, .cameraZoom]

    /// Both orbit axes. Prefer the independent permissions for new code.
    public static let rotate: Self = [.heading, .pitch]
    /// Both zoom permissions. The input configuration still chooses its explicit target.
    public static let zoom: Self = [.groundZoom, .cameraZoom]
    public static let pan: Self = .groundPan

    var gestureTypes: Set<DioramaGestureType> {
        var result: Set<DioramaGestureType> = []
        if contains(.heading) { result.insert(.heading) }
        if contains(.pitch) { result.insert(.pitch) }
        if contains(.groundPan) { result.insert(.pan) }
        if contains(.groundZoom) { result.insert(.zoom) }
        if contains(.cameraZoom) { result.insert(.cameraZoom) }
        return result
    }
}
