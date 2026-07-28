import Foundation

/// A building footprint: a closed ring of coordinates and a height.
public struct BuildingFootprint: Sendable, Equatable, Hashable {
    /// The outline, in geographic coordinates, wound in whatever order the source stored it.
    ///
    /// Open, not closed — the first point is not repeated at the end, because extrusion and
    /// triangulation both treat an outline as implicitly closed and a duplicated point would put a
    /// zero-length wall in the mesh.
    public let outline: [Coordinate]
    /// Height above the ground in real meters.
    public let heightMeters: Double

    public init(outline: [Coordinate], heightMeters: Double) {
        self.outline = outline
        self.heightMeters = heightMeters
    }
}

/// Somewhere building footprints come from.
///
/// Two implementations ship, and they are not interchangeable in the way a protocol usually
/// suggests. ``OSMBuildingProvider`` queries the live OpenStreetMap database through Overpass:
/// authoritative, unlimited in area, and a service whose usage policy asks that applications not
/// point end users at it. ``MapTilerBuildingProvider`` reads the same data pre-baked into vector
/// tiles: fast, cacheable, meant to be called by applications, and needing an API key. The protocol
/// exists so `DioramaStore` can be handed either without knowing which, and so a test can be handed
/// neither.
public protocol BuildingProvider: Sendable {
    /// Fetches every building footprint inside the bounding box.
    ///
    /// - Parameters:
    ///   - south: Southern latitude bound.
    ///   - west: Western longitude bound.
    ///   - north: Northern latitude bound.
    ///   - east: Eastern longitude bound.
    func fetchBuildings(
        south: Double,
        west: Double,
        north: Double,
        east: Double
    ) async throws -> [BuildingFootprint]
}

/// Where a diorama's buildings come from.
///
/// Shaped like ``ImagerySource`` and ``ElevationSource``: a case per service, carrying the key when
/// the service needs one.
public enum BuildingSource: Sendable, Equatable {
    /// The live OpenStreetMap database, through the public Overpass API. No key, no ceremony, and
    /// slow enough — tens of seconds when the instances are busy — that it suits development rather
    /// than shipping.
    case openStreetMap
    /// MapTiler's `openmaptiles` vector tiles, which is the same OSM data pre-baked. Fast, and the
    /// key is likely already to hand since this package uses MapTiler for imagery and terrain too.
    case mapTiler(apiKey: String)

    /// Builds the provider this source names, with the style's height conventions applied.
    func makeProvider(style: BuildingStyle) -> any BuildingProvider {
        switch self {
        case .openStreetMap:
            return OSMBuildingProvider(
                maximumBuildings: style.maximumBuildings,
                defaultHeightMeters: style.defaultHeightMeters,
                metersPerLevel: style.metersPerLevel
            )
        case .mapTiler(let apiKey):
            return MapTilerBuildingProvider(
                apiKey: apiKey,
                maximumBuildings: style.maximumBuildings,
                defaultHeightMeters: style.defaultHeightMeters
            )
        }
    }
}
