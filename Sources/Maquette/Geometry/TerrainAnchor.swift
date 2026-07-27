import Foundation
import simd

/// The fixed relationship between diorama space and the world.
///
/// Diorama X/Z are placed against **Web Mercator tile space** at a single zoom, where a whole tile
/// is one unit and a coordinate's tile position is its longitude and latitude projected and scaled.
/// That projection is linear in tile space, which is what lets the map be a scale and a translation
/// rather than a per-sample projection.
///
/// The anchor exists because the mapping used to be implicit: whatever tiles happened to be loaded
/// were stretched across the chunk's extent, so the ground a diorama position named depended on
/// which tiles were resident. Adding a tile moved the terrain. Naming the map explicitly separates
/// *where the ground is* from *what is currently in memory*, which is what a rolling fetch needs —
/// tiles can arrive and be evicted without the terrain shifting underneath the chunk.
public struct TerrainAnchor: Sendable, Equatable {
    /// Zoom level the tile coordinates are expressed at.
    public let zoom: Int
    /// Fractional tile coordinate that sits at diorama X/Z = 0.
    public let originTile: SIMD2<Double>
    /// Tile-space units spanned by one diorama meter, along X and Z.
    ///
    /// Separate per axis because a mosaic is not always square, and the mapping it replaced was
    /// per-axis too.
    public let tilesPerDioramaMeter: SIMD2<Double>

    /// Creates an anchor from an explicit origin and scale.
    public init(zoom: Int, originTile: SIMD2<Double>, tilesPerDioramaMeter: SIMD2<Double>) {
        self.zoom = zoom
        self.originTile = originTile
        self.tilesPerDioramaMeter = tilesPerDioramaMeter
    }

    /// Creates an anchor that places a geographic coordinate at the diorama origin.
    ///
    /// - Parameters:
    ///   - coordinate: The coordinate to put at diorama X/Z = 0.
    ///   - zoom: Zoom level to express tile coordinates at.
    ///   - extent: Physical size of the region in diorama meters.
    ///   - radiusMeters: Real-world radius that `extent` spans, measured at the coordinate.
    public init(centeredOn coordinate: Coordinate, zoom: Int, extent: SIMD2<Float>, radiusMeters: Double) {
        // Tiles are square in Mercator, so one scale covers both axes; the extent's aspect is
        // carried by the region's tile span rather than by the scale.
        let metersPerTile = TileMath.metersPerTile(latitude: coordinate.latitude, zoom: zoom)
        let dioramaMetersPerRealMeter = Double(extent.x) / (radiusMeters * 2)
        let tilesPerMeter = 1 / (metersPerTile * dioramaMetersPerRealMeter)
        self.init(
            zoom: zoom,
            originTile: TileMath.tilePoint(for: coordinate, zoom: zoom),
            tilesPerDioramaMeter: SIMD2(tilesPerMeter, tilesPerMeter)
        )
    }

    /// Creates the anchor that stretches a rectangle of tiles across a diorama extent.
    ///
    /// This reproduces the mapping the library used before anchors existed, where the loaded mosaic
    /// *was* the region. Use it to keep a fixed chunk behaving exactly as it did; a chunk that pans
    /// wants a geographic anchor instead, so that the map survives the mosaic changing.
    public init(
        mosaicMinTile: SIMD2<Int>,
        tilesWide: Int,
        tilesTall: Int,
        extent: SIMD2<Float>,
        zoom: Int
    ) {
        let span = SIMD2(Double(tilesWide), Double(tilesTall))
        let extentD = SIMD2(Double(extent.x), Double(extent.y))
        self.init(
            zoom: zoom,
            originTile: SIMD2(Double(mosaicMinTile.x), Double(mosaicMinTile.y)) + span / 2,
            tilesPerDioramaMeter: SIMD2(
                extentD.x > 0 ? span.x / extentD.x : 0,
                extentD.y > 0 ? span.y / extentD.y : 0
            )
        )
    }

    /// The fractional tile coordinate a diorama X/Z position falls on.
    public func tilePoint(forDioramaX x: Double, z: Double) -> SIMD2<Double> {
        originTile + SIMD2(x, z) * tilesPerDioramaMeter
    }

    /// The diorama X/Z position a fractional tile coordinate falls on.
    public func dioramaPoint(forTilePoint tile: SIMD2<Double>) -> SIMD2<Double> {
        let delta = tile - originTile
        return SIMD2(
            tilesPerDioramaMeter.x != 0 ? delta.x / tilesPerDioramaMeter.x : 0,
            tilesPerDioramaMeter.y != 0 ? delta.y / tilesPerDioramaMeter.y : 0
        )
    }

    /// The diorama X/Z position a geographic coordinate falls on.
    public func dioramaPoint(for coordinate: Coordinate) -> SIMD2<Double> {
        dioramaPoint(forTilePoint: TileMath.tilePoint(for: coordinate, zoom: zoom))
    }

    /// The geographic coordinate at a diorama X/Z position.
    public func coordinate(forDioramaX x: Double, z: Double) -> Coordinate {
        TileMath.coordinate(forTilePoint: tilePoint(forDioramaX: x, z: z), zoom: zoom)
    }

    /// An anchor shifted by whole tiles, leaving every geographic position it names unchanged.
    ///
    /// Panning far enough would otherwise grow the offset without bound, and a `Float` offset
    /// measured in diorama meters loses resolution long before it reaches the far side of the
    /// planet. Folding whole tiles of pan into the anchor keeps the offset small and the arithmetic
    /// exact, because a whole-tile shift is exact in both spaces.
    ///
    /// It pairs with a matching subtraction from the pan offset: shifting forward by `tiles` and
    /// reducing the offset by `tiles * dioramaMetersPerTile` names exactly the same ground.
    public func shifted(byTiles tiles: SIMD2<Int>) -> TerrainAnchor {
        TerrainAnchor(
            zoom: zoom,
            originTile: originTile + SIMD2(Double(tiles.x), Double(tiles.y)),
            tilesPerDioramaMeter: tilesPerDioramaMeter
        )
    }

    /// Diorama meters spanned by one whole tile, along X and Z.
    public var dioramaMetersPerTile: SIMD2<Double> {
        SIMD2(
            tilesPerDioramaMeter.x != 0 ? 1 / tilesPerDioramaMeter.x : 0,
            tilesPerDioramaMeter.y != 0 ? 1 / tilesPerDioramaMeter.y : 0
        )
    }
}
