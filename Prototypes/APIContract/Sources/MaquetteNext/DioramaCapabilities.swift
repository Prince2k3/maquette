/// Capability inputs are supplied by a rendering host, never inferred from an OS name.
public struct DioramaCapabilities: Sendable, Equatable {
    public enum Presentation: Sendable { case orbit, augmentedReality, volume }
    public enum Surface: Sendable {
        case raster
        case photorealisticWithoutQueries
        case photorealisticWithPointQueries
        case photorealisticWithDraping
    }

    public let camera: DioramaCameraCapabilities
    public let canClampToSurface: Bool
    public let canDrapeAreas: Bool

    public init(presentation: Presentation, surface: Surface) {
        camera = presentation == .orbit ? .orbit : .unavailable
        canClampToSurface = surface != .photorealisticWithoutQueries
        canDrapeAreas = surface == .raster || surface == .photorealisticWithDraping
    }
}
