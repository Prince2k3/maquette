/// Permissions are intents, independent of whether touch, pointer, or keyboard produces them.
public struct DioramaInteractionModes: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let heading = Self(rawValue: 1 << 0)
    public static let pitch = Self(rawValue: 1 << 1)
    public static let groundPan = Self(rawValue: 1 << 2)
    public static let groundZoom = Self(rawValue: 1 << 3)
    public static let cameraZoom = Self(rawValue: 1 << 4)
    public static let all: Self = [.heading, .pitch, .groundPan, .groundZoom, .cameraZoom]
}
