import Foundation
import simd

/// A continuous elevation surface sampled from a mosaic of tile elevation grids.
///
/// The height field presents the loaded tiles as a single surface addressable by diorama-space
/// X/Z coordinates, hiding the tile mosaic behind bilinear interpolation. Mesh generation samples
/// it at arbitrary positions — including positions that fall between grid samples, which is what
/// boundary clipping requires.
///
/// ## Vertical convention
///
/// `surfaceY(atX:z:)` returns diorama-space Y where **0 is the lowest terrain elevation** in the
/// loaded region. Terrain rises into positive Y; the chunk's earth mass extends into negative Y.
/// Every consumer of diorama-space Y — markers, polylines, the water plane, `ElevationSampler` —
/// shares this convention.
public struct TerrainHeightField: Sendable {
    /// Decoded elevation grids, one per tile.
    public let grids: [ElevationGrid]
    /// Tile x/y positions corresponding to each grid.
    public let tilePositions: [(x: Int, y: Int)]
    /// Physical size of the sampled region in diorama meters: X width, Z depth.
    public let extent: SIMD2<Float>
    /// Lowest raw elevation (meters above sea level) across all grids. Maps to diorama Y = 0.
    public let minElevation: Float
    /// Highest raw elevation (meters above sea level) across all grids.
    public let maxElevation: Float
    /// Converts raw elevation meters into diorama-space meters.
    public let elevationScale: Float

    private let minTileX: Int
    private let minTileY: Int
    private let tilesWide: Int
    private let tilesTall: Int
    /// Index into `grids` for each mosaic slot, or `nil` where no tile was loaded.
    private let gridIndexBySlot: [Int?]

    /// Creates a height field from loaded elevation grids.
    ///
    /// - Parameters:
    ///   - grids: Decoded elevation grids, one per tile.
    ///   - tilePositions: Tile x/y positions corresponding to each grid.
    ///   - extent: Physical size of the region in diorama meters (X width, Z depth).
    ///   - elevationScale: Converts raw elevation meters into diorama-space meters.
    ///     Pass `0` to flatten the terrain.
    ///   - baselineElevation: Raw elevation that maps to diorama Y = 0. Defaults to the lowest
    ///     elevation across the grids.
    public init(
        grids: [ElevationGrid],
        tilePositions: [(x: Int, y: Int)],
        extent: SIMD2<Float>,
        elevationScale: Float,
        baselineElevation: Float? = nil
    ) {
        precondition(grids.count == tilePositions.count, "grids and tilePositions must correspond")
        precondition(!grids.isEmpty, "TerrainHeightField requires at least one grid")

        self.grids = grids
        self.tilePositions = tilePositions
        self.extent = extent
        self.elevationScale = elevationScale
        self.minElevation = baselineElevation ?? (grids.map(\.minElevation).min() ?? 0)
        self.maxElevation = grids.map(\.maxElevation).max() ?? 0

        let minTX = tilePositions.map(\.x).min() ?? 0
        let minTY = tilePositions.map(\.y).min() ?? 0
        let maxTX = tilePositions.map(\.x).max() ?? 0
        let maxTY = tilePositions.map(\.y).max() ?? 0
        self.minTileX = minTX
        self.minTileY = minTY
        self.tilesWide = maxTX - minTX + 1
        self.tilesTall = maxTY - minTY + 1

        var slots = [Int?](repeating: nil, count: (maxTX - minTX + 1) * (maxTY - minTY + 1))
        for (index, position) in tilePositions.enumerated() {
            let slot = (position.y - minTY) * (maxTX - minTX + 1) + (position.x - minTX)
            slots[slot] = index
        }
        self.gridIndexBySlot = slots
    }

    /// The highest point of the terrain surface in diorama-space Y.
    public var maxSurfaceY: Float {
        (maxElevation - minElevation) * elevationScale
    }

    /// The terrain's total vertical relief in diorama-space meters.
    public var relief: Float {
        maxSurfaceY
    }

    /// Returns the raw elevation (meters above sea level) at a diorama-space X/Z position.
    ///
    /// Positions outside the sampled region clamp to the nearest edge sample.
    public func rawElevation(atX x: Float, z: Float) -> Float {
        // Normalize into 0...1 across the mosaic.
        let nx = ((x + extent.x / 2) / extent.x).clampedToUnitRange
        let nz = ((z + extent.y / 2) / extent.y).clampedToUnitRange

        // Locate the tile and the fractional position within it.
        let tileFx = nx * Float(tilesWide)
        let tileFz = nz * Float(tilesTall)
        let tileX = min(Int(tileFx), tilesWide - 1)
        let tileZ = min(Int(tileFz), tilesTall - 1)
        let fracX = (tileFx - Float(tileX)).clampedToUnitRange
        let fracZ = (tileFz - Float(tileZ)).clampedToUnitRange

        guard let gridIndex = gridIndexBySlot[tileZ * tilesWide + tileX] else {
            // A gap in the mosaic — fall back to the baseline so the surface stays continuous.
            return minElevation
        }

        return grids[gridIndex].bilinearElevation(fracX: fracX, fracY: fracZ)
    }

    /// Returns the terrain surface height in diorama-space Y at a diorama-space X/Z position.
    ///
    /// Y = 0 corresponds to the lowest elevation in the loaded region.
    public func surfaceY(atX x: Float, z: Float) -> Float {
        (rawElevation(atX: x, z: z) - minElevation) * elevationScale
    }
}

extension ElevationGrid {
    /// Bilinearly samples the grid at a fractional position, where 0 is the first sample
    /// and 1 is the last sample along each axis.
    func bilinearElevation(fracX: Float, fracY: Float) -> Float {
        let gx = fracX * Float(width - 1)
        let gy = fracY * Float(height - 1)

        let x0 = min(max(Int(gx), 0), width - 1)
        let y0 = min(max(Int(gy), 0), height - 1)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)

        let tx = gx - Float(x0)
        let ty = gy - Float(y0)

        let e00 = elevation(atColumn: x0, row: y0)
        let e10 = elevation(atColumn: x1, row: y0)
        let e01 = elevation(atColumn: x0, row: y1)
        let e11 = elevation(atColumn: x1, row: y1)

        let top = e00 + (e10 - e00) * tx
        let bottom = e01 + (e11 - e01) * tx
        return top + (bottom - top) * ty
    }
}

extension Float {
    var clampedToUnitRange: Float {
        Swift.min(Swift.max(self, 0), 1)
    }
}
