import CoreLocation
import Foundation

/// Retains decoded elevation grids and provides bilinear-interpolated terrain height at any geographic coordinate.
///
/// Constructed after tile loading completes. Used by `DioramaProxy` to position markers and polylines
/// at correct terrain heights.
public struct ElevationSampler: Sendable {
    /// Decoded elevation grids, one per tile.
    public let grids: [ElevationGrid]
    /// Tile x/y positions corresponding to each grid.
    public let tilePositions: [(x: Int, y: Int)]
    /// Zoom level used for tile fetching.
    public let zoom: Int
    /// Geographic center of the diorama.
    public let center: CLLocationCoordinate2D
    /// Geographic radius in meters.
    public let radiusMeters: Double
    /// Physical diameter of the diorama in meters.
    public let physicalDiameter: Float
    /// Elevation exaggeration multiplier.
    public let exaggeration: Float
    /// Global minimum elevation across all grids (used as baseline).
    public let globalMinElev: Float

    /// Creates an elevation sampler from loaded terrain data.
    public init(
        grids: [ElevationGrid],
        tilePositions: [(x: Int, y: Int)],
        zoom: Int,
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        physicalDiameter: Float,
        exaggeration: Float,
        globalMinElev: Float
    ) {
        self.grids = grids
        self.tilePositions = tilePositions
        self.zoom = zoom
        self.center = center
        self.radiusMeters = radiusMeters
        self.physicalDiameter = physicalDiameter
        self.exaggeration = exaggeration
        self.globalMinElev = globalMinElev
        self.heightField = TerrainHeightField(
            grids: grids,
            tilePositions: tilePositions,
            extent: SIMD2(physicalDiameter, physicalDiameter),
            elevationScale: physicalDiameter / Float(radiusMeters * 2.0) * exaggeration,
            baselineElevation: globalMinElev
        )
    }

    /// The terrain surface this sampler reads from — the same surface the chunk mesh is built on.
    private let heightField: TerrainHeightField

    /// Returns a 3D position in diorama-space for the given geographic coordinate.
    ///
    /// X/Z come from the tile mosaic layout and Y is read from the shared `TerrainHeightField`,
    /// so a sampled position lands exactly on the generated chunk surface.
    ///
    /// Returns `nil` if the coordinate falls outside the loaded tiles.
    ///
    /// - Parameter coordinate: The geographic coordinate to project.
    /// - Returns: A 3D position in diorama-space meters, or `nil` if outside bounds.
    public func position(for coordinate: CLLocationCoordinate2D) -> SIMD3<Float>? {
        guard let point = horizontalPosition(for: coordinate) else { return nil }
        return SIMD3(point.x, heightField.surfaceY(atX: point.x, z: point.y), point.y)
    }

    /// Maps a geographic coordinate onto the diorama's horizontal plane.
    ///
    /// Returns `nil` if the coordinate falls outside the loaded tiles.
    public func horizontalPosition(for coordinate: CLLocationCoordinate2D) -> SIMD2<Float>? {
        let coord = Coordinate(coordinate)
        let tileCoord = TileMath.tileXY(for: coord, zoom: zoom)

        guard tilePositions.contains(where: { $0.x == tileCoord.x && $0.y == tileCoord.y }) else {
            return nil
        }

        let bounds = TileMath.tileBounds(x: tileCoord.x, y: tileCoord.y, zoom: zoom)

        // Fractional position within the tile.
        let fracX = (coord.longitude - bounds.minLongitude) / (bounds.maxLongitude - bounds.minLongitude)
        let fracY = (bounds.maxLatitude - coord.latitude) / (bounds.maxLatitude - bounds.minLatitude)
        let clampedFracX = Float(max(0, min(1, fracX)))
        let clampedFracY = Float(max(0, min(1, fracY)))

        let minTX = tilePositions.map(\.x).min()!
        let minTY = tilePositions.map(\.y).min()!
        let maxTX = tilePositions.map(\.x).max()!
        let maxTY = tilePositions.map(\.y).max()!
        let tilesWide = Float(maxTX - minTX + 1)
        let tilesTall = Float(maxTY - minTY + 1)

        // Tiles tile the extent edge to edge, so the mosaic position is simply the tile index
        // plus the fraction within it.
        let mosaicX = (Float(tileCoord.x - minTX) + clampedFracX) / tilesWide
        let mosaicZ = (Float(tileCoord.y - minTY) + clampedFracY) / tilesTall

        return SIMD2(
            (mosaicX - 0.5) * heightField.extent.x,
            (mosaicZ - 0.5) * heightField.extent.y
        )
    }

    /// Returns the terrain elevation (in diorama-space Y) at the given geographic coordinate.
    ///
    /// Uses bilinear interpolation within the elevation grid for smooth results.
    /// Returns `nil` if the coordinate falls outside the loaded tiles.
    ///
    /// - Parameter coordinate: The geographic coordinate to sample.
    /// - Returns: The Y position in diorama-space meters, or `nil` if outside bounds.
    public func elevation(at coordinate: CLLocationCoordinate2D) -> Float? {
        position(for: coordinate)?.y
    }
}
