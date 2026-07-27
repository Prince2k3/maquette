import CoreGraphics
import Foundation
import simd

/// A rectangle of tiles, in absolute tile coordinates at a single zoom.
///
/// Columns are deliberately *unwrapped*: panning east past the antimeridian keeps counting, so a
/// window can straddle it and still be a rectangle. Only the request that actually goes to a
/// provider is folded back into `0..<2^zoom`.
struct TerrainTileWindow: Equatable, Sendable {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var tilesWide: Int { maxX - minX + 1 }
    var tilesTall: Int { maxY - minY + 1 }

    var tiles: [TileCoordinate] {
        guard maxX >= minX, maxY >= minY else { return [] }
        var result: [TileCoordinate] = []
        result.reserveCapacity(tilesWide * tilesTall)
        for y in minY...maxY {
            for x in minX...maxX {
                result.append(TileCoordinate(x: x, y: y))
            }
        }
        return result
    }

    func contains(_ other: TerrainTileWindow) -> Bool {
        minX <= other.minX && maxX >= other.maxX && minY <= other.minY && maxY >= other.maxY
    }

    /// The window covering a set of tiles, or `nil` if there are none.
    static func covering(_ tiles: some Collection<TileCoordinate>) -> TerrainTileWindow? {
        guard let first = tiles.first else { return nil }
        var window = TerrainTileWindow(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for tile in tiles.dropFirst() {
            window.minX = min(window.minX, tile.x)
            window.maxX = max(window.maxX, tile.x)
            window.minY = min(window.minY, tile.y)
            window.maxY = max(window.maxY, tile.y)
        }
        return window
    }
}

/// The tile data a rolling chunk currently holds.
///
/// Elevation is kept *unstitched*: stitching reconciles a grid's edge against whichever neighbours
/// are loaded, so it has to be redone for the new set each time the window moves rather than
/// accumulated.
struct TerrainTileSet: Sendable {
    var grids: [TileCoordinate: ElevationGrid] = [:]
    var imagery: [TileCoordinate: Data] = [:]

    var isEmpty: Bool { grids.isEmpty }
}

/// One completed roll: the ground the chunk should be sampling now.
struct TerrainRoll: Sendable {
    /// The tile data to carry into the next roll.
    let tiles: TerrainTileSet
    /// The window actually loaded, which is the requested one minus anything that failed to fetch.
    let window: TerrainTileWindow
    /// The surface built from `tiles`, against the roller's fixed anchor.
    let heightField: TerrainHeightField
    /// Imagery composited over exactly `window`, or `nil` if none of it decoded.
    let imagery: CGImage?
}

/// Keeps a panning terrain chunk supplied with ground.
///
/// The chunk's outline is fixed and the terrain slides beneath it, so panning far enough always
/// reaches past whatever was fetched. The roller works out which tiles the chunk is sitting on at
/// the current offset, fetches the ones missing, and hands back a height field built against the
/// **same anchor** every time.
///
/// That last part is what makes the swap invisible. The mapping from a diorama position to the
/// ground is the anchor's, not the mosaic's, so changing which tiles are resident does not move the
/// terrain — which is precisely what a rolling fetch would otherwise do on every step.
struct TerrainRoller: Sendable {
    /// Zoom the window's tile coordinates are expressed at.
    let zoom: Int
    /// The fixed diorama-to-ground mapping every rolled height field is built against.
    let anchor: TerrainAnchor
    /// Converts raw elevation meters into diorama-space meters.
    let elevationScale: Float
    /// Raw elevation that maps to diorama Y = 0.
    ///
    /// Frozen at the initial load. If it tracked the resident tiles the chunk would bob as higher
    /// or lower ground rolled in, which the library's vertical convention forbids.
    let baselineElevation: Float
    /// Diorama-space rectangle the chunk samples, before the pan offset moves it.
    let chunkMin: SIMD2<Float>
    let chunkMax: SIMD2<Float>
    /// Ring of tiles kept beyond the chunk, so ordinary panning is served without a fetch.
    let marginTiles: SIMD2<Int>
    let terrainProvider: any TileProvider
    let satelliteProvider: any TileProvider
    /// MapTiler ships terrain as WebP and needs its own decoder.
    let decodesMapTilerTerrain: Bool
    let cache: TileCache

    /// How many tiles are fetched at once. Enough to keep the connection busy without asking a
    /// free tile server for a hundred images in one breath.
    private static let concurrentFetches = 8

    /// The tiles the chunk needs loaded at a given pan offset, plus the margin ring.
    func window(forPanOffset offset: SIMD2<Float>) -> TerrainTileWindow {
        let low = chunkMin + offset
        let high = chunkMax + offset
        let a = anchor.tilePoint(forDioramaX: Double(low.x), z: Double(low.y))
        let b = anchor.tilePoint(forDioramaX: Double(high.x), z: Double(high.y))
        let lo = simd_min(a, b)
        let hi = simd_max(a, b)

        var window = TerrainTileWindow(
            minX: Int(lo.x.rounded(.down)) - marginTiles.x,
            minY: Int(lo.y.rounded(.down)) - marginTiles.y,
            maxX: Int(hi.x.rounded(.down)) + marginTiles.x,
            maxY: Int(hi.y.rounded(.down)) + marginTiles.y
        )

        // Mercator ends at ±85°, so rows run out; columns never do, because they wrap.
        let rows = tileCount
        if rows > 0 {
            window.minY = min(max(window.minY, 0), rows - 1)
            window.maxY = min(max(window.maxY, 0), rows - 1)
        }
        return window
    }

    /// Fetches whatever `window` needs that `have` does not, and builds the surface from the result.
    ///
    /// Returns `nil` only if nothing at all could be loaded, which leaves the caller on the ground
    /// it already had rather than dropping the chunk into a void.
    func load(window: TerrainTileWindow, have: TerrainTileSet) async -> TerrainRoll? {
        var set = TerrainTileSet()
        var missing: [TileCoordinate] = []
        for tile in window.tiles {
            if let grid = have.grids[tile], let imagery = have.imagery[tile] {
                set.grids[tile] = grid
                set.imagery[tile] = imagery
            } else {
                missing.append(tile)
            }
        }

        for fetched in await fetch(missing) {
            set.grids[fetched.tile] = fetched.grid
            set.imagery[fetched.tile] = fetched.imagery
        }

        guard let loaded = TerrainTileWindow.covering(set.grids.keys) else { return nil }

        // Row-major, so the stitcher and the composite walk the mosaic the same way.
        let ordered = set.grids.keys.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        let positions = ordered.map { (x: $0.x, y: $0.y) }
        var grids = ordered.compactMap { set.grids[$0] }
        if grids.count > 1 {
            grids = MeshStitcher.stitchEdges(
                grids: grids,
                tilePositions: positions,
                resolution: grids[0].width
            )
        }

        let heightField = TerrainHeightField(
            grids: grids,
            tilePositions: positions,
            anchor: anchor,
            elevationScale: elevationScale,
            baselineElevation: baselineElevation
        )

        // The imagery has to span exactly the tiles the height field holds, because they share one
        // mapping — anything else slides the picture off the ground it belongs to.
        let imageryTiles = ordered.compactMap { tile in
            set.imagery[tile].map { (x: tile.x, y: tile.y, data: $0) }
        }
        let imagery = try? DioramaMaterials.compositeSatelliteImage(
            tiles: imageryTiles,
            minX: loaded.minX,
            minY: loaded.minY,
            tilesWide: loaded.tilesWide,
            tilesTall: loaded.tilesTall
        )

        return TerrainRoll(tiles: set, window: loaded, heightField: heightField, imagery: imagery)
    }

    // MARK: - Fetching

    private var tileCount: Int {
        guard zoom >= 0, zoom < 31 else { return 0 }
        return 1 << zoom
    }

    /// Folds a window coordinate into a coordinate a provider will accept.
    ///
    /// Columns wrap — the world is a cylinder — so panning east forever keeps asking for real
    /// tiles. Rows do not: past the poles there is nothing to ask for.
    private func requestCoordinate(for tile: TileCoordinate) -> TileCoordinate? {
        let count = tileCount
        guard count > 0 else { return tile }
        guard tile.y >= 0, tile.y < count else { return nil }
        return TileCoordinate(x: ((tile.x % count) + count) % count, y: tile.y)
    }

    private func fetch(
        _ tiles: [TileCoordinate]
    ) async -> [(tile: TileCoordinate, grid: ElevationGrid, imagery: Data)] {
        guard !tiles.isEmpty else { return [] }

        return await withTaskGroup(
            of: (tile: TileCoordinate, grid: ElevationGrid, imagery: Data)?.self
        ) { group in
            var results: [(tile: TileCoordinate, grid: ElevationGrid, imagery: Data)] = []
            results.reserveCapacity(tiles.count)

            var iterator = tiles.makeIterator()
            for _ in 0..<min(Self.concurrentFetches, tiles.count) {
                guard let tile = iterator.next() else { break }
                group.addTask { await fetchOne(tile) }
            }

            while let result = await group.next() {
                if let result { results.append(result) }
                if let tile = iterator.next() {
                    group.addTask { await fetchOne(tile) }
                }
            }
            return results
        }
    }

    private func fetchOne(
        _ tile: TileCoordinate
    ) async -> (tile: TileCoordinate, grid: ElevationGrid, imagery: Data)? {
        guard let request = requestCoordinate(for: tile) else { return nil }
        do {
            async let elevationData = cache.cachedOrFetch(
                x: request.x, y: request.y, zoom: zoom, provider: terrainProvider
            )
            async let imageryData = cache.cachedOrFetch(
                x: request.x, y: request.y, zoom: zoom, provider: satelliteProvider
            )
            let elevation = try await elevationData
            let imagery = try await imageryData
            let grid = decodesMapTilerTerrain
                ? try MapTilerTerrainProvider.decodeElevation(from: elevation)
                : try TerrainTileProvider.decodeElevation(from: elevation)
            return (tile: tile, grid: grid, imagery: imagery)
        } catch {
            // A tile that fails simply stays absent: the height field clamps across the gap and the
            // next roll asks for it again.
            return nil
        }
    }
}
