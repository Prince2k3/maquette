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
    }

    /// Returns a 3D position in diorama-space for the given geographic coordinate.
    ///
    /// Uses the **same tile-grid layout** as `TerrainMeshGenerator` so the returned X/Z match the
    /// terrain mesh surface exactly. Y is bilinear-interpolated from the elevation grid and
    /// transformed with the same scale/exaggeration as the mesh vertices.
    ///
    /// Returns `nil` if the coordinate falls outside the loaded tiles.
    ///
    /// - Parameter coordinate: The geographic coordinate to project.
    /// - Returns: A 3D position in diorama-space meters, or `nil` if outside bounds.
    public func position(for coordinate: CLLocationCoordinate2D) -> SIMD3<Float>? {
        let coord = Coordinate(coordinate)

        // Find which tile this coordinate falls in
        let tileCoord = TileMath.tileXY(for: coord, zoom: zoom)

        // Find the matching grid
        guard let gridIndex = tilePositions.firstIndex(where: {
            $0.x == tileCoord.x && $0.y == tileCoord.y
        }) else {
            return nil
        }

        let grid = grids[gridIndex]
        let bounds = TileMath.tileBounds(x: tileCoord.x, y: tileCoord.y, zoom: zoom)

        // Compute fractional position within the tile (0..1)
        let fracX = (coord.longitude - bounds.minLongitude) / (bounds.maxLongitude - bounds.minLongitude)
        let fracY = (bounds.maxLatitude - coord.latitude) / (bounds.maxLatitude - bounds.minLatitude)

        // Clamp to valid range
        let clampedFracX = Float(max(0, min(1, fracX)))
        let clampedFracY = Float(max(0, min(1, fracY)))

        // --- Compute X/Z using the same tile-grid layout as TerrainMeshGenerator ---
        let minTX = tilePositions.map(\.x).min()!
        let minTY = tilePositions.map(\.y).min()!
        let maxTX = tilePositions.map(\.x).max()!
        let maxTY = tilePositions.map(\.y).max()!
        let tilesWide = maxTX - minTX + 1
        let tilesTall = maxTY - minTY + 1

        let tileSizeX = physicalDiameter / Float(tilesWide)
        let tileSizeZ = physicalDiameter / Float(tilesTall)

        let tx = tileCoord.x - minTX
        let ty = tileCoord.y - minTY

        let tileOffsetX = Float(tx) * tileSizeX - physicalDiameter / 2.0 + tileSizeX / 2.0
        let tileOffsetZ = Float(ty) * tileSizeZ - physicalDiameter / 2.0 + tileSizeZ / 2.0

        // Position within the tile: fracX/fracY map 0..1 across the tile's physical extent
        let x = tileOffsetX + (clampedFracX - 0.5) * tileSizeX
        let z = tileOffsetZ + (clampedFracY - 0.5) * tileSizeZ

        // --- Bilinear-interpolate elevation (Y) ---
        let gridX = Double(clampedFracX) * Double(grid.width - 1)
        let gridY = Double(clampedFracY) * Double(grid.height - 1)

        let x0 = Int(floor(gridX))
        let y0 = Int(floor(gridY))
        let x1 = min(x0 + 1, grid.width - 1)
        let y1 = min(y0 + 1, grid.height - 1)

        let xFrac = Float(gridX - Double(x0))
        let yFrac = Float(gridY - Double(y0))

        let e00 = grid.elevation(atColumn: x0, row: y0)
        let e10 = grid.elevation(atColumn: x1, row: y0)
        let e01 = grid.elevation(atColumn: x0, row: y1)
        let e11 = grid.elevation(atColumn: x1, row: y1)

        let rawElevation = e00 * (1 - xFrac) * (1 - yFrac)
            + e10 * xFrac * (1 - yFrac)
            + e01 * (1 - xFrac) * yFrac
            + e11 * xFrac * yFrac

        // Apply the same transform as the terrain mesh generator:
        // y = (rawElev - globalMinElev) * geographicScale * exaggeration
        let geographicScale = physicalDiameter / Float(radiusMeters * 2.0)
        let elevationScale = geographicScale * exaggeration

        let y = (rawElevation - globalMinElev) * elevationScale

        return SIMD3<Float>(x, y, z)
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
