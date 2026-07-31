import Foundation
import simd

/// A continuous elevation surface sampled from a mosaic of tile elevation grids.
///
/// The height field presents the loaded tiles as a single surface addressable by diorama-space
/// X/Z coordinates, hiding the tile mosaic behind bilinear interpolation. Mesh generation samples
/// it at arbitrary positions — including positions that fall between grid samples, which is what
/// boundary clipping requires.
///
/// ## Where the ground is, versus what is loaded
///
/// A `TerrainAnchor` fixes which ground a diorama position names; the loaded grids are merely the
/// part of that ground currently in memory. The two are deliberately separate, so tiles can arrive
/// and be evicted without the terrain sliding under the chunk. Sampling outside the resident tiles
/// clamps to the nearest edge — a rolling fetch keeps the chunk covered, and clamping is the
/// gentler failure while tiles are still in flight.
///
/// ## Vertical convention
///
/// `surfaceY(atX:z:)` returns diorama-space Y where **0 is ``baselineElevation``** — the lowest
/// terrain elevation in the region, unless a caller hands in another. Terrain rises into positive Y;
/// the chunk's earth mass extends into negative Y. Every consumer of diorama-space Y — markers,
/// polylines, the water plane, `ElevationSampler` — shares this convention, and shares it *because*
/// they all read it from here rather than restating it.
///
/// The one caller that hands in another is the ground zoom, which anchors Y = 0 to the chunk's rim
/// rather than to its floor so the strata band keeps its height as the map widens. Everything above
/// still holds — it is one affine map either way — but "Y = 0 is the lowest ground" is true at the
/// scale the chunk was generated at and not at every scale it is read at.
struct TerrainHeightField: Sendable {
    /// Decoded elevation grids, one per tile.
    public let grids: [ElevationGrid]
    /// Tile x/y positions corresponding to each grid.
    public let tilePositions: [(x: Int, y: Int)]
    /// How diorama X/Z maps onto the world.
    public let anchor: TerrainAnchor
    /// The raw elevation (meters above sea level) that maps to diorama Y = 0.
    ///
    /// The lowest elevation in the region unless a caller says otherwise, which is what makes
    /// Y = 0 the chunk's floor at the scale it was generated at. A ground zoom hands in a different
    /// one — see ``DioramaStore/setGroundScale(_:)`` — so this is *not* a minimum, and the name says
    /// so: read as one it would licence exactly the assumption a zoomed chunk breaks.
    public let baselineElevation: Float
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

    // Panning re-samples the whole surface every frame, so the per-sample arithmetic is hot.
    // These fold the anchor into window-relative `Float`s, which is also what keeps the precision
    // bounded: absolute tile coordinates run to 2^zoom, far past what a Float resolves finely
    // enough to sample a 256-wide grid with.
    private let originInWindow: SIMD2<Float>
    private let tilesPerDioramaMeter: SIMD2<Float>
    private let tilesWideFloat: Float
    private let tilesTallFloat: Float

    /// Creates a height field from loaded elevation grids and an explicit ground mapping.
    ///
    /// - Parameters:
    ///   - grids: Decoded elevation grids, one per tile.
    ///   - tilePositions: Tile x/y positions corresponding to each grid, at the anchor's zoom.
    ///   - anchor: How diorama X/Z maps onto the world.
    ///   - elevationScale: Converts raw elevation meters into diorama-space meters.
    ///     Pass `0` to flatten the terrain.
    ///   - baselineElevation: Raw elevation that maps to diorama Y = 0. Defaults to the lowest
    ///     elevation across the grids. Pass the value the chunk was generated with when rolling
    ///     new tiles in, or the chunk bobs as the ground moves beneath it.
    public init(
        grids: [ElevationGrid],
        tilePositions: [(x: Int, y: Int)],
        anchor: TerrainAnchor,
        elevationScale: Float,
        baselineElevation: Float? = nil
    ) {
        precondition(grids.count == tilePositions.count, "grids and tilePositions must correspond")
        precondition(!grids.isEmpty, "TerrainHeightField requires at least one grid")

        self.grids = grids
        self.tilePositions = tilePositions
        self.anchor = anchor
        self.elevationScale = elevationScale
        self.baselineElevation = baselineElevation ?? (grids.map(\.minElevation).min() ?? 0)
        self.maxElevation = grids.map(\.maxElevation).max() ?? 0

        let minTX = tilePositions.map(\.x).min() ?? 0
        let minTY = tilePositions.map(\.y).min() ?? 0
        let maxTX = tilePositions.map(\.x).max() ?? 0
        let maxTY = tilePositions.map(\.y).max() ?? 0
        self.minTileX = minTX
        self.minTileY = minTY
        self.tilesWide = maxTX - minTX + 1
        self.tilesTall = maxTY - minTY + 1
        self.tilesWideFloat = Float(maxTX - minTX + 1)
        self.tilesTallFloat = Float(maxTY - minTY + 1)

        let originInWindow = anchor.originTile - SIMD2(Double(minTX), Double(minTY))
        self.originInWindow = SIMD2(Float(originInWindow.x), Float(originInWindow.y))
        self.tilesPerDioramaMeter = SIMD2(
            Float(anchor.tilesPerDioramaMeter.x),
            Float(anchor.tilesPerDioramaMeter.y)
        )

        var slots = [Int?](repeating: nil, count: (maxTX - minTX + 1) * (maxTY - minTY + 1))
        for (index, position) in tilePositions.enumerated() {
            let slot = (position.y - minTY) * (maxTX - minTX + 1) + (position.x - minTX)
            slots[slot] = index
        }
        self.gridIndexBySlot = slots
    }

    /// Creates a height field that stretches the loaded mosaic across a diorama extent.
    ///
    /// The mosaic *is* the region here, which is the right mapping for a chunk whose tiles never
    /// change. A chunk that pans past its fetched tiles wants a geographic anchor instead, so that
    /// the ground stays put as tiles come and go.
    ///
    /// - Parameters:
    ///   - grids: Decoded elevation grids, one per tile.
    ///   - tilePositions: Tile x/y positions corresponding to each grid.
    ///   - extent: Physical size of the region in diorama meters (X width, Z depth).
    ///   - elevationScale: Converts raw elevation meters into diorama-space meters.
    ///     Pass `0` to flatten the terrain.
    ///   - baselineElevation: Raw elevation that maps to diorama Y = 0. Defaults to the lowest
    ///     elevation across the grids.
    ///   - zoom: Zoom level the tile positions are expressed at. Only geographic conversions read
    ///     it, so a field built from synthetic grids can leave it at zero.
    public init(
        grids: [ElevationGrid],
        tilePositions: [(x: Int, y: Int)],
        extent: SIMD2<Float>,
        elevationScale: Float,
        baselineElevation: Float? = nil,
        zoom: Int = 0
    ) {
        let minTX = tilePositions.map(\.x).min() ?? 0
        let minTY = tilePositions.map(\.y).min() ?? 0
        let maxTX = tilePositions.map(\.x).max() ?? 0
        let maxTY = tilePositions.map(\.y).max() ?? 0
        self.init(
            grids: grids,
            tilePositions: tilePositions,
            anchor: TerrainAnchor(
                mosaicMinTile: SIMD2(minTX, minTY),
                tilesWide: maxTX - minTX + 1,
                tilesTall: maxTY - minTY + 1,
                extent: extent,
                zoom: zoom
            ),
            elevationScale: elevationScale,
            baselineElevation: baselineElevation
        )
    }

    /// Physical size of the resident tiles in diorama meters: X width, Z depth.
    ///
    /// This is the *loaded* region, not the reachable one — it grows and shrinks as tiles roll in
    /// and out. The chunk's own size comes from its boundary.
    public var extent: SIMD2<Float> {
        let perTile = anchor.dioramaMetersPerTile
        return SIMD2(Float(Double(tilesWide) * perTile.x), Float(Double(tilesTall) * perTile.y))
    }

    /// The highest point of the terrain surface in diorama-space Y.
    public var maxSurfaceY: Float {
        (maxElevation - baselineElevation) * elevationScale
    }

    /// The terrain's total vertical relief in diorama-space meters.
    public var relief: Float {
        maxSurfaceY
    }

    /// The position of a diorama X/Z point within the resident tiles, in tiles from their corner.
    ///
    /// Clamped to the loaded mosaic, so a position beyond it reads as its nearest edge.
    @inline(__always)
    func windowPoint(atX x: Float, z: Float) -> SIMD2<Float> {
        SIMD2(
            min(max(originInWindow.x + x * tilesPerDioramaMeter.x, 0), tilesWideFloat),
            min(max(originInWindow.y + z * tilesPerDioramaMeter.y, 0), tilesTallFloat)
        )
    }

    /// Whether a diorama X/Z point falls on a tile that is currently loaded.
    ///
    /// A rolling fetch uses this to decide what still has to arrive; sampling an unloaded point is
    /// allowed and clamps to the nearest edge rather than failing.
    public func isResident(atX x: Float, z: Float) -> Bool {
        let point = SIMD2(
            originInWindow.x + x * tilesPerDioramaMeter.x,
            originInWindow.y + z * tilesPerDioramaMeter.y
        )
        guard point.x >= 0, point.x <= tilesWideFloat, point.y >= 0, point.y <= tilesTallFloat else {
            return false
        }
        let tileX = min(Int(point.x), tilesWide - 1)
        let tileZ = min(Int(point.y), tilesTall - 1)
        return gridIndexBySlot[tileZ * tilesWide + tileX] != nil
    }

    /// Texture coordinate for a diorama X/Z point within the imagery composited over the resident
    /// tiles.
    ///
    /// The imagery mosaic and the elevation mosaic cover the same tiles, so one mapping serves
    /// both — and both follow the anchor, so a rolling fetch moves them together.
    ///
    /// **V is flipped.** The two mosaics are indexed from opposite ends: rows count southward from
    /// the window's northern tile, while RealityKit's texture origin is the bottom left, so V
    /// counts up from the image's southern edge. `GLBParser` documents the same trap on the
    /// photorealistic path. Without the flip the imagery is mirrored north–south, which on its own
    /// is nearly invisible — mirrored aerial imagery still reads as aerial imagery — and stays
    /// invisible for as long as the window holds still.
    ///
    /// It becomes very visible the moment a roll moves the window's *rows*. The mirror reflects
    /// about the window's middle row, so the ground a point samples is `2·minY + height − row`:
    /// shifting the window one tile north moves the picture two tiles south, in one frame. Columns
    /// are exactly invariant, which is why panning east for kilometres looked perfect and panning
    /// north popped to different ground. `TerrainRollerTests.rollingDoesNotShiftTheImagery`
    /// measured that jump at a full tile of ground per row rolled, against zero on the X axis.
    @inline(__always)
    public func textureCoordinate(atX x: Float, z: Float) -> SIMD2<Float> {
        let point = windowPoint(atX: x, z: z)
        return SIMD2(
            tilesWideFloat > 0 ? point.x / tilesWideFloat : 0,
            tilesTallFloat > 0 ? 1 - point.y / tilesTallFloat : 0
        )
    }

    /// Returns the raw elevation (meters above sea level) at a diorama-space X/Z position.
    ///
    /// Positions outside the loaded tiles clamp to the nearest edge sample.
    @inline(__always)
    public func rawElevation(atX x: Float, z: Float) -> Float {
        // Locate the tile and the fractional position within it.
        let point = windowPoint(atX: x, z: z)
        let tileX = min(Int(point.x), tilesWide - 1)
        let tileZ = min(Int(point.y), tilesTall - 1)
        let fracX = (point.x - Float(tileX)).clampedToUnitRange
        let fracZ = (point.y - Float(tileZ)).clampedToUnitRange

        guard let gridIndex = gridIndexBySlot[tileZ * tilesWide + tileX] else {
            // A gap in the mosaic — fall back to the baseline so the surface stays continuous.
            return baselineElevation
        }

        return grids[gridIndex].bilinearElevation(fracX: fracX, fracY: fracZ)
    }

    /// Returns the terrain surface height in diorama-space Y at a diorama-space X/Z position.
    ///
    /// Y = 0 corresponds to the lowest elevation in the loaded region.
    @inline(__always)
    public func surfaceY(atX x: Float, z: Float) -> Float {
        (rawElevation(atX: x, z: z) - baselineElevation) * elevationScale
    }

    /// Everything a surface vertex needs from the terrain at one point.
    public struct SurfaceSample: Sendable {
        /// Terrain height in diorama-space Y.
        public var y: Float
        /// Shading normal, differentiated from the bilinear patch the height came from.
        public var normal: SIMD3<Float>
        /// Where the point falls in the composited imagery, in 0...1.
        public var textureCoordinate: SIMD2<Float>
    }

    /// Samples the height, shading normal, and imagery coordinate at one point together.
    ///
    /// Asked for separately these are six calls that each re-derive the same thing — the window
    /// transform, the tile lookup, the borrow of that tile's value array — and the slope used to
    /// need four extra heights either side of the point on top of that. It needs none: the height
    /// comes from a bilinear patch, and a bilinear patch is a closed form whose derivative falls out
    /// of the four corners already read. So one interpolation answers all three, and there is no
    /// sampling step left to choose, since the slope is the surface's own rather than a measurement
    /// of it.
    ///
    /// What that gives up is that a bilinear patch's slope is discontinuous at every cell boundary —
    /// constant along one axis within a cell — so in principle shading facets wherever the mesh
    /// resolves finer than the elevation grid. Measured against the central-difference form on the
    /// Pan preset it does not: the two renders differ by a median of 3/255 with no visible faceting
    /// on either peaks or plateau, and the resample halves.
    ///
    /// Panning re-samples every vertex of the surface, so this runs tens of thousands of times a
    /// step and is the reason the combined form exists at all.
    @inline(__always)
    public func surfaceSample(atX x: Float, z: Float) -> SurfaceSample {
        let center = windowPoint(atX: x, z: z)
        let tileX = min(Int(center.x), tilesWide - 1)
        let tileZ = min(Int(center.y), tilesTall - 1)

        let patch: ElevationGrid.Patch
        if let index = gridIndexBySlot[tileZ * tilesWide + tileX] {
            patch = grids[index].bilinearPatch(
                fracX: (center.x - Float(tileX)).clampedToUnitRange,
                fracY: (center.y - Float(tileZ)).clampedToUnitRange
            )
        } else {
            // A gap in the mosaic falls back to the baseline, so the surface stays continuous.
            patch = ElevationGrid.Patch(value: baselineElevation, gradient: .zero)
        }

        // The gradient is per unit of fractional position across a tile; `tilesPerDioramaMeter`
        // takes it to per diorama meter, and `elevationScale` to diorama Y.
        let slope = patch.gradient * tilesPerDioramaMeter * elevationScale

        return SurfaceSample(
            y: (patch.value - baselineElevation) * elevationScale,
            normal: simd_normalize(SIMD3(-slope.x, 1, -slope.y)),
            textureCoordinate: SIMD2(
                tilesWideFloat > 0 ? center.x / tilesWideFloat : 0,
                tilesTallFloat > 0 ? 1 - center.y / tilesTallFloat : 0
            )
        )
    }
}

extension ElevationGrid {
    /// Bilinearly samples the grid at a fractional position, where 0 is the first sample
    /// and 1 is the last sample along each axis.
    @inline(__always)
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

    /// A bilinear sample and the slope of the same patch, in one read of the four corners.
    struct Patch {
        /// Interpolated elevation, in meters above sea level.
        var value: Float
        /// How that elevation changes per unit of fractional position across the tile.
        var gradient: SIMD2<Float>
    }

    /// Bilinearly samples the grid and differentiates the same patch analytically.
    ///
    /// A bilinear patch is a closed form, so its slope is available from the four corners already
    /// read for the value — which is one interpolation where central differences take five. The
    /// cost is that the slope is exact for the patch rather than for the terrain: it jumps at every
    /// cell boundary, where four sampled heights either side of the point cross the boundary
    /// smoothly. That shows up as faceting on ground where a mesh cell spans more than a grid cell.
    @inline(__always)
    func bilinearPatch(fracX: Float, fracY: Float) -> Patch {
        let cellsX = Float(width - 1)
        let cellsY = Float(height - 1)
        let gx = fracX * cellsX
        let gy = fracY * cellsY

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

        // Differentiating h = top + (bottom − top)·ty. Along x the two edge slopes are blended by
        // ty; along y the difference between the edges *is* the slope. Both are scaled by the
        // number of cells, since the fractional position spans the whole tile rather than one cell.
        let alongX = ((e10 - e00) + ((e11 - e01) - (e10 - e00)) * ty) * cellsX
        let alongY = (bottom - top) * cellsY

        return Patch(value: top + (bottom - top) * ty, gradient: SIMD2(alongX, alongY))
    }
}

extension Float {
    var clampedToUnitRange: Float {
        Swift.min(Swift.max(self, 0), 1)
    }
}
