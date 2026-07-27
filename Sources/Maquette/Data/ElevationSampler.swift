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
            baselineElevation: globalMinElev,
            zoom: zoom
        )
    }

    /// The terrain surface this sampler reads from — the same surface the chunk mesh is built on.
    private let heightField: TerrainHeightField

    /// How far the terrain has slid beneath the chunk's outline, in diorama meters.
    ///
    /// A coordinate keeps its place on the ground, so when the ground moves the coordinate's
    /// diorama position moves with it.
    public var panOffset: SIMD2<Float> = .zero

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
        // The terrain is sampled where the coordinate actually sits; the chunk shows that point
        // shifted by however far the ground has been panned.
        return SIMD3(
            point.x - panOffset.x,
            heightField.surfaceY(atX: point.x, z: point.y),
            point.y - panOffset.y
        )
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

        // The chunk's own ground mapping, so a marker lands where the mesh put that ground.
        let point = heightField.anchor.dioramaPoint(for: coord)
        return SIMD2(Float(point.x), Float(point.y))
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
