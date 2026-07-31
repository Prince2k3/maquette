import Foundation
import os
import simd

/// Fetches building footprints from MapTiler's `openmaptiles` vector tiles.
///
/// The same OpenStreetMap data ``OSMBuildingProvider`` queries live, pre-baked into tiles: minutes
/// become milliseconds, the service is one meant to be called by applications rather than one that
/// asks not to be, and the key is likely already to hand since this package uses MapTiler for
/// imagery and terrain too.
///
/// ## Zoom 14 is not a quality knob
///
/// OpenMapTiles carries `building` from zoom 14 and the source's maximum zoom *is* 14 — deeper
/// zooms are served by over-zooming the z14 tile, not by fetching a more detailed one. So 14 is the
/// only zoom that answers, and asking for 15 gets a 404 rather than sharper buildings. The geometry
/// grid is 4096 across a tile that spans roughly 2.4 km at San Francisco's latitude, which puts the
/// quantization at about 0.6 m — under a millimetre once a kilometre of ground is scaled onto a
/// chunk, and finer than the footprints themselves are surveyed.
///
/// ## Heights are already resolved
///
/// The schema does the work `OSMBuildingProvider.height(from:)` has to do by hand: `render_height`
/// arrives in metres with OSM's `height`, `building:levels` and unit suffixes already reconciled.
/// What it does not carry is anything to reconcile them *from*, so a building the schema could not
/// resolve simply has no `render_height` and falls back to the configured default, the same as an
/// untagged one does on the Overpass path.
///
/// ## What it does not do
///
/// Interior rings are dropped rather than punched out. A courtyard is a hole in a footprint, and
/// `BuildingFootprint` is a single ring — so a building with one is drawn solid across its
/// courtyard. That matches the Overpass path, which reads closed ways and skips the multipolygon
/// relations that describe exactly these, and it is the conservative direction: a filled courtyard
/// is a wrong roof, while treating the hole as its own footprint would stand a second building
/// inside the first.
///
/// `render_min_height` is likewise ignored, so a footprint that should float — a walkway between
/// two towers — sits on the ground instead.
public struct MapTilerBuildingProvider: BuildingProvider {
    private static let logger = Logger(maquette: "MapTilerBuildingProvider")

    /// The MapTiler API key.
    public let apiKey: String
    /// How many buildings to keep. Beyond this the fetch is truncated and the drop is logged.
    public let maximumBuildings: Int
    /// Height drawn for a building the schema could not resolve a height for.
    public let defaultHeightMeters: Double

    private let httpClient: any HTTPClient

    /// The only zoom the `building` layer exists at. See the note above.
    static let zoom = 14
    /// The layer this reads out of a tile carrying twenty or so.
    private static let layerName = "building"
    /// How many tiles one fetch will ask for before it decides the bounding box is a mistake. A
    /// chunk's bbox is two or three tiles; a hundred is a region the size of a small country, which
    /// no diorama asks for and which would take the rate limit down with it.
    private static let maximumTiles = 100

    public init(
        apiKey: String,
        maximumBuildings: Int = 12_000,
        defaultHeightMeters: Double = 8,
        httpClient: any HTTPClient = URLSession.shared
    ) {
        self.apiKey = apiKey
        self.maximumBuildings = maximumBuildings
        self.defaultHeightMeters = defaultHeightMeters
        self.httpClient = httpClient
    }

    public func fetchBuildings(
        south: Double,
        west: Double,
        north: Double,
        east: Double
    ) async throws -> [BuildingFootprint] {
        let zoom = Self.zoom
        let topLeft = TileMath.tileXY(
            for: Coordinate(latitude: north, longitude: west), zoom: zoom
        )
        let bottomRight = TileMath.tileXY(
            for: Coordinate(latitude: south, longitude: east), zoom: zoom
        )

        var tiles: [TileCoordinate] = []
        for y in min(topLeft.y, bottomRight.y)...max(topLeft.y, bottomRight.y) {
            for x in min(topLeft.x, bottomRight.x)...max(topLeft.x, bottomRight.x) {
                tiles.append(TileCoordinate(x: x, y: y))
            }
        }
        guard tiles.count <= Self.maximumTiles else {
            throw DioramaError.invalidConfiguration(
                reason: """
                    the buildings bounding box spans \(tiles.count) vector tiles at zoom \(zoom), \
                    past the \(Self.maximumTiles) a single fetch will ask for
                    """
            )
        }

        // Fetched together rather than in turn: they are independent requests over the same
        // connection, and a chunk's handful of tiles finishes in about the time one of them takes.
        var footprints: [BuildingFootprint] = []
        try await withThrowingTaskGroup(of: [BuildingFootprint].self) { group in
            for tile in tiles {
                group.addTask {
                    try await self.buildings(inTileX: tile.x, y: tile.y, zoom: zoom)
                }
            }
            for try await tileFootprints in group {
                footprints.append(contentsOf: tileFootprints)
            }
        }

        return deduplicated(footprints)
    }

    // MARK: - One tile

    /// Fetches and decodes one tile's buildings, in geographic coordinates.
    func buildings(inTileX x: Int, y: Int, zoom: Int) async throws -> [BuildingFootprint] {
        guard let data = try await fetchTile(x: x, y: y, zoom: zoom) else { return [] }
        let tile = try VectorTile(data: data)
        guard let layer = tile.layer(named: Self.layerName) else { return [] }
        return footprints(from: layer, tileX: x, tileY: y, zoom: zoom)
    }

    /// Returns the tile's bytes, or `nil` where the service says there is nothing there.
    private func fetchTile(x: Int, y: Int, zoom: Int) async throws -> Data? {
        let urlString = "https://api.maptiler.com/tiles/v3/\(zoom)/\(x)/\(y).pbf?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw DioramaError.invalidConfiguration(reason: "could not build a MapTiler tile URL")
        }
        var request = URLRequest(url: url)
        request.setValue(MaquetteHTTP.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }

        switch http.statusCode {
        case 204:
            // An empty tile — ocean, or open country. Not an error.
            return nil
        case 200...299:
            return data
        case 401, 403:
            throw DioramaError.authenticationFailed(provider: "MapTiler")
        case 404:
            // The tile pyramid is sparse: a tile with nothing in it is not published at all, which
            // is indistinguishable from a mistyped path and has to be read as the common case.
            return nil
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Int.init)
            throw DioramaError.rateLimited(provider: "MapTiler", retryAfter: retryAfter)
        default:
            throw DioramaError.tileNotFound(x: x, y: y, zoom: zoom)
        }
    }

    // MARK: - Decoding

    /// Turns a decoded `building` layer into footprints. Separated from the fetch so it can be
    /// tested against synthetic tile bytes without a network or a key.
    func footprints(
        from layer: VectorTileLayer,
        tileX: Int,
        tileY: Int,
        zoom: Int
    ) -> [BuildingFootprint] {
        let extent = Double(layer.extent)
        var footprints: [BuildingFootprint] = []

        for feature in layer.features {
            guard feature.geometryType == .polygon else { continue }
            // `hide_3d` marks a footprint that `building:part` geometry stands in for. Extruding it
            // as well would put a plain block through the middle of the detailed one.
            if feature.attributes["hide_3d"]?.boolean == true { continue }

            let height = feature.attributes["render_height"]?.number ?? defaultHeightMeters

            for ring in feature.rings where ring.isExterior {
                guard ring.points.count >= 3 else { continue }
                let outline = ring.points.map { point in
                    TileMath.coordinate(
                        forTilePoint: SIMD2(
                            Double(tileX) + Double(point.x) / extent,
                            Double(tileY) + Double(point.y) / extent
                        ),
                        zoom: zoom
                    )
                }
                footprints.append(BuildingFootprint(outline: outline, heightMeters: height))
            }
        }
        return footprints
    }

    /// Drops the buildings the tile grid repeats, and applies the cap.
    ///
    /// Encoders buffer geometry past a tile's edge, so a building lying wholly inside that margin is
    /// encoded **complete in both** neighbouring tiles. Both copies decode to bit-identical
    /// coordinates — the grid positions are integers and the conversion is exact — so an equality
    /// test finds them, and extruding both would double the geometry along every seam.
    ///
    /// A building *straddling* the edge is a different thing that looks similar: it appears in both
    /// tiles as two different partials, and the two together are the shape. They compare unequal and
    /// are therefore kept, which is the right answer — dropping one would leave half a building.
    private func deduplicated(_ footprints: [BuildingFootprint]) -> [BuildingFootprint] {
        var seen = Set<[Coordinate]>()
        var kept: [BuildingFootprint] = []
        kept.reserveCapacity(min(footprints.count, maximumBuildings))
        var duplicates = 0

        for footprint in footprints {
            guard seen.insert(footprint.outline).inserted else {
                duplicates += 1
                continue
            }
            guard kept.count < maximumBuildings else { break }
            kept.append(footprint)
        }

        if duplicates > 0 || kept.count < footprints.count - duplicates {
            Self.logger.info(
                """
                Kept \(kept.count) building footprints from MapTiler; dropped \(duplicates) \
                repeated across tile seams and \(footprints.count - duplicates - kept.count) \
                past the \(self.maximumBuildings) cap
                """
            )
        }
        return kept
    }
}
