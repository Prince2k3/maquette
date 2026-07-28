import Foundation
import RealityKit
import os

/// Loading state for the diorama.
public enum DioramaLoadingState: Sendable {
    /// Not yet started loading.
    case idle
    /// Currently fetching tiles and generating meshes.
    case loading
    /// Successfully loaded and ready to display.
    case loaded
    /// An error occurred during loading.
    case failed(DioramaError)
}

/// How much of a streaming presentation has arrived.
///
/// Only the photorealistic 3D Tiles path streams. A terrain chunk is finished the moment
/// `DioramaLoadingState` reaches `.loaded`, so it reports no progress at all — `nil` rather than a
/// completed value, since "nothing to wait for" and "waiting for nothing" want different UI.
///
/// A streaming presentation reaches `.loaded` as soon as its root tileset arrives, which is long
/// before there is much to look at. That is deliberate: the model is displayable and improving from
/// that point on, and blocking behind a full-screen spinner until it settled would hide it for the
/// whole time it was most obviously getting better. This is what fills the gap.
///
/// The denominator is not known up front, and cannot be. A 3D Tiles tree is discovered as it is
/// walked — each tile that arrives may name children the traversal had never heard of — so
/// `tilesPending` is what the *latest* traversal still wants, not what the finished model will have
/// needed. `fractionComplete` therefore climbs, stalls, and sometimes steps backwards as detail
/// comes into view. Show it as a sign of life rather than a countdown, and let `isStreaming` decide
/// whether to show anything at all.
public struct DioramaStreamingProgress: Sendable, Equatable {
    /// Tiles held as drawable geometry.
    public let tilesLoaded: Int
    /// Content the latest traversal asked for and does not yet have.
    public let tilesPending: Int
    /// Whether more content is still on its way.
    ///
    /// `false` once the view is either fully covered or waiting on a camera move to ask for
    /// anything further, which are the two states in which an indicator has nothing left to say.
    public let isStreaming: Bool

    /// Share of the currently known work that is done, in `0...1`.
    public var fractionComplete: Double {
        let total = tilesLoaded + tilesPending
        guard total > 0 else { return isStreaming ? 0 : 1 }
        return Double(tilesLoaded) / Double(total)
    }

    public init(tilesLoaded: Int, tilesPending: Int, isStreaming: Bool) {
        self.tilesLoaded = tilesLoaded
        self.tilesPending = tilesPending
        self.isStreaming = isStreaming
    }
}

/// Domain store responsible for orchestrating tile fetching, mesh generation, and entity assembly.
@Observable
@MainActor
public final class DioramaStore {
    /// Current loading state.
    public private(set) var loadingState: DioramaLoadingState = .idle

    /// The root diorama entity, available once loading completes.
    public private(set) var dioramaEntity: Entity?

    /// The active configuration.
    public var configuration: DioramaConfiguration

    /// Elevation sampler for terrain height queries, available after terrain loading completes.
    public private(set) var elevationSampler: ElevationSampler?

    /// The active route preview entity, if one was applied via content.
    public private(set) var routePreviewEntity: RoutePreviewEntity?

    /// How much of a streaming presentation has arrived, or `nil` if this one does not stream.
    ///
    /// Computed rather than stored so it stays live: the counters belong to the tile manager, and
    /// reading them here is what registers a SwiftUI view for their updates.
    public var streamingProgress: DioramaStreamingProgress? {
        (dioramaEntity as? DioramaEntity)?.tiles3D?.streamingProgress
    }

    private let tileCache = TileCache()
    private let logger = Logger(subsystem: "com.maquette", category: "DioramaStore")

    /// Creates a store with the given configuration.
    public init(configuration: DioramaConfiguration) {
        self.configuration = configuration
    }

    /// Starts the async loading pipeline: fetch tiles, generate meshes, assemble entity tree.
    public func load() async {
        guard case .idle = loadingState else { return }
        loadingState = .loading

        do {
            let rootEntity = DioramaEntity()

            // The two presentations are separate pipelines, not two sources for one.
            switch configuration.presentation {
            case .terrainChunk:
                try await loadTerrainPipeline(into: rootEntity)

            case .photorealistic(let provider, let style):
                try await loadPhotorealisticPipeline(provider: provider, style: style, into: rootEntity)
            }

            dioramaEntity = rootEntity
            loadingState = .loaded
            rebuildEffect()
            logger.info("Diorama loaded successfully")

        } catch let error as DioramaError {
            loadingState = .failed(error)
            logger.error("Diorama loading failed: \(error)")
        } catch {
            loadingState = .failed(.networkFailure(message: error.localizedDescription))
            logger.error("Diorama loading failed: \(error)")
        }
    }

    /// Resets the store to its initial state, discarding the loaded entity.
    public func reset() {
        rollTask?.cancel()
        rollTask = nil
        buildingsTask?.cancel()
        buildingsTask = nil
        rolling = nil
        samplerTemplate = nil
        effectPass = nil
        loadingState = .idle
        dioramaEntity = nil
        elevationSampler = nil
        routePreviewEntity = nil
        panOffset = .zero
    }

    // MARK: - Effects

    /// The visual effect painted over the built diorama.
    public private(set) var effect: DioramaEffect = .none

    private var effectPass: (any DioramaEffectPass)?

    /// Applies a visual effect, or `.none` to put the diorama back as its configuration describes it.
    ///
    /// An effect is a restyle of the finished scene, so changing one never refetches a tile or
    /// rebuilds the chunk. Setting it before the diorama has loaded is fine — it is applied as soon
    /// as there is something to apply it to.
    public func setEffect(_ effect: DioramaEffect) {
        guard effect != self.effect else { return }
        self.effect = effect
        rebuildEffect()
    }

    private var effectContext: DioramaEffectContext {
        DioramaEffectContext(
            boundary: configuration.boundary,
            elevationScale: configuration.geographicScale * (samplerTemplate?.exaggeration ?? 1),
            baselineElevation: samplerTemplate?.globalMinElev ?? 0
        )
    }

    private func rebuildEffect() {
        guard let root = dioramaEntity as? DioramaEntity else { return }
        effectPass?.revert(from: root)
        effectPass = effect.makePass()
        effectPass?.apply(to: root, context: effectContext)
    }

    /// Re-traces an effect after the ground beneath the outline has changed.
    ///
    /// Contours are isolines of the surface's own height, so every pan step moves every one of them.
    private func refreshEffect() {
        guard let root = dioramaEntity as? DioramaEntity else { return }
        effectPass?.refresh(on: root, context: effectContext)
    }

    /// Re-takes an effect over a scene whose own materials have been replaced beneath it.
    ///
    /// A roll hands the chunk fresh imagery, which is both the material the effect had painted over
    /// and the one it has to hand back when it is switched off. Reverting first would put the
    /// *previous* window's picture on the new window's ground, so the pass re-reads what is there
    /// now instead.
    private func reapplyEffect() {
        guard let root = dioramaEntity as? DioramaEntity else { return }
        effectPass?.reapply(to: root, context: effectContext)
    }

    // MARK: - Terrain Mesh Pipeline

    /// Loads terrain + satellite imagery and assembles the terrain entity.
    private func loadTerrainPipeline(into rootEntity: DioramaEntity) async throws {
        let center = Coordinate(configuration.center)
        // Zoom is chosen from the chunk's own radius so panning does not coarsen the detail;
        // a wider pan region simply means more tiles at the same zoom.
        let zoom = configuration.zoomLevel ?? TileMath.optimalZoomLevel(
            radiusMeters: configuration.radiusMeters,
            latitude: center.latitude
        )

        let fetchRadius = configuration.terrainFetchRadiusMeters
        let tiles = TileMath.tilesInRegion(
            center: center,
            radiusMeters: fetchRadius,
            zoom: zoom
        )

        logger.debug("Loading \(tiles.count) tiles at zoom \(zoom), radius \(fetchRadius)m")

        // Select providers based on configuration
        let terrainProvider: any TileProvider = switch configuration.elevationSource {
        case .mapzen:
            TerrainTileProvider()
        case .mapTiler(let apiKey):
            MapTilerTerrainProvider(apiKey: apiKey)
        }

        let satelliteProvider: any TileProvider = switch configuration.imagerySource {
        case .esriSatellite:
            SatelliteTileProvider()
        case .mapTilerSatellite(let apiKey):
            MapTilerSatelliteProvider(apiKey: apiKey)
        }

        let useMapTilerTerrain: Bool = if case .mapTiler = configuration.elevationSource { true } else { false }

        var terrainGrids: [(x: Int, y: Int, grid: ElevationGrid)] = []
        var satelliteImages: [(x: Int, y: Int, data: Data)] = []

        for tile in tiles {
            async let terrainData = tileCache.cachedOrFetch(
                x: tile.x, y: tile.y, zoom: zoom,
                provider: terrainProvider
            )
            async let satelliteData = tileCache.cachedOrFetch(
                x: tile.x, y: tile.y, zoom: zoom,
                provider: satelliteProvider
            )

            let tData = try await terrainData
            let sData = try await satelliteData

            // Use ImageIO-based decoder for MapTiler (WebP), PNG decoder for Mapzen
            let grid: ElevationGrid
            if useMapTilerTerrain {
                grid = try MapTilerTerrainProvider.decodeElevation(from: tData)
            } else {
                grid = try TerrainTileProvider.decodeElevation(from: tData)
            }
            terrainGrids.append((x: tile.x, y: tile.y, grid: grid))
            satelliteImages.append((x: tile.x, y: tile.y, data: sData))
        }

        // Kept unstitched for the roller: stitching reconciles a grid against whichever neighbours
        // are loaded, so it has to be redone for each new window rather than accumulated.
        let rawGrids = terrainGrids

        // Stitch adjacent tile edges to eliminate seams in multi-tile meshes
        if terrainGrids.count > 1 {
            let stitchedGrids = MeshStitcher.stitchEdges(
                grids: terrainGrids.map(\.grid),
                tilePositions: terrainGrids.map { (x: $0.x, y: $0.y) },
                resolution: terrainGrids[0].grid.width
            )
            terrainGrids = zip(terrainGrids, stitchedGrids).map { original, stitchedGrid in
                (x: original.x, y: original.y, grid: stitchedGrid)
            }
        }

        let exaggeration = configuration.effectiveExaggeration
        let elevationScale = configuration.geographicScale * exaggeration

        // The fetched mosaic is stretched across the fetched region, which fixes the scale and the
        // origin for good. Every subsequent roll reuses this anchor, so tiles can come and go
        // without the ground moving beneath the chunk.
        let initialWindow = TerrainTileWindow.covering(
            terrainGrids.map { TileCoordinate(x: $0.x, y: $0.y) }
        ) ?? TerrainTileWindow(minX: 0, minY: 0, maxX: 0, maxY: 0)
        let anchor = TerrainAnchor(
            mosaicMinTile: SIMD2(initialWindow.minX, initialWindow.minY),
            tilesWide: initialWindow.tilesWide,
            tilesTall: initialWindow.tilesTall,
            extent: configuration.terrainRegionExtent,
            zoom: zoom
        )

        // The imagery mosaic spans the full tile grid, so the height field does too. The chunk
        // boundary is then cut out of that region — smaller than the region when panning is on,
        // and the leftover margin is what the terrain slides through.
        let heightField = TerrainHeightField(
            grids: terrainGrids.map(\.grid),
            tilePositions: terrainGrids.map { (x: $0.x, y: $0.y) },
            anchor: anchor,
            elevationScale: elevationScale
        )
        let globalMinElev = heightField.minElevation

        let boundary = configuration.boundary
        let chunkStyle = configuration.chunk
        let baseDepth = chunkStyle.baseDepth.resolved(
            horizontalExtent: max(boundary.extent.x, boundary.extent.y),
            relief: heightField.relief
        )

        let wallMaterial = DioramaMaterials.wallMaterial(for: chunkStyle.wall)
        let solid = try TerrainSolidGenerator.generate(
            heightField: heightField,
            boundary: boundary,
            baseDepth: baseDepth,
            includesWalls: wallMaterial != nil,
            includesBottom: chunkStyle.closesBottom
        )

        logger.debug("Generated terrain chunk with base depth \(baseDepth)m")

        // Create satellite material — composite multiple tiles if needed
        let terrainMaterial: RealityKit.Material
        if satelliteImages.count > 1 {
            let minX = satelliteImages.map(\.x).min()!
            let minY = satelliteImages.map(\.y).min()!
            let maxX = satelliteImages.map(\.x).max()!
            let maxY = satelliteImages.map(\.y).max()!
            let tilesWide = maxX - minX + 1
            let tilesTall = maxY - minY + 1

            terrainMaterial = try DioramaMaterials.compositeSatelliteMaterial(
                tiles: satelliteImages,
                minX: minX,
                minY: minY,
                tilesWide: tilesWide,
                tilesTall: tilesTall
            )
        } else if let firstTile = satelliteImages.first {
            terrainMaterial = (try? DioramaMaterials.satelliteTextureMaterial(from: firstTile.data))
                ?? TerrainEntity.fallbackMaterial()
        } else {
            terrainMaterial = TerrainEntity.fallbackMaterial()
        }

        let terrainEntity = TerrainEntity(
            parts: solid,
            surfaceMaterial: terrainMaterial,
            wallMaterial: wallMaterial,
            bottomMaterial: chunkStyle.closesBottom
                ? DioramaMaterials.bottomMaterial(color: chunkStyle.bottomColor)
                : nil,
            pannableTerrain: configuration.panRange > 0 ? heightField : nil
        )
        rootEntity.setTerrain(terrainEntity)

        // Add water plane if terrain has sea-level areas
        if globalMinElev <= 0 && exaggeration > 0 {
            let waterY = (0.0 - globalMinElev) * elevationScale
            if let waterEntity = WaterPlaneEntity.generate(boundary: boundary, waterY: waterY) {
                rootEntity.setWaterPlane(waterEntity)
            }
        }

        // The chunk's own display base, positioned against its underside.
        if let baseEntity = try? DioramaBase.generate(
            style: chunkStyle.base,
            boundary: boundary,
            chunkBottomY: -baseDepth
        ) {
            rootEntity.setBase(baseEntity)
        }

        // Retain elevation data for marker/polyline positioning. The sampler covers the whole
        // fetched region, so markers outside the chunk are still placeable once panned into view.
        samplerTemplate = SamplerTemplate(
            zoom: zoom,
            anchor: anchor,
            exaggeration: exaggeration,
            globalMinElev: globalMinElev
        )
        setElevationSampler(grids: terrainGrids)

        // Panning slides the chunk off its fetched tiles sooner or later, so it keeps the machinery
        // to fetch more. What it does not keep is a limit: the ground rolls in as the offset grows.
        if configuration.panRange > 0 {
            let perTile = anchor.dioramaMetersPerTile
            let margin = configuration.maximumPanOffset
            let roller = TerrainRoller(
                zoom: zoom,
                anchor: anchor,
                elevationScale: elevationScale,
                baselineElevation: globalMinElev,
                chunkMin: boundary.minCorner,
                chunkMax: boundary.minCorner + boundary.extent,
                marginTiles: SIMD2(
                    Self.marginTiles(meters: margin.x, perTile: perTile.x),
                    Self.marginTiles(meters: margin.y, perTile: perTile.y)
                ),
                terrainProvider: terrainProvider,
                satelliteProvider: satelliteProvider,
                decodesMapTilerTerrain: useMapTilerTerrain,
                cache: tileCache
            )
            var tiles = TerrainTileSet()
            for entry in rawGrids {
                tiles.grids[TileCoordinate(x: entry.x, y: entry.y)] = entry.grid
            }
            for entry in satelliteImages {
                tiles.imagery[TileCoordinate(x: entry.x, y: entry.y)] = entry.data
            }
            rolling = TerrainRollState(roller: roller, tiles: tiles, window: initialWindow)
        }

        startBuildingsFetch(heightField: heightField, boundary: boundary, rootEntity: rootEntity)
    }

    // MARK: - Buildings

    private var buildingsTask: Task<Void, Never>?

    /// Fetches OpenStreetMap footprints and stands them on the chunk, without holding up the load.
    ///
    /// Detached from the pipeline because Overpass is slow — a public instance answers a downtown
    /// query in seconds, sometimes tens of them — and terrain the user can already look at is worth
    /// more than buildings that arrive at the same moment.
    private func startBuildingsFetch(
        heightField: TerrainHeightField,
        boundary: DioramaBoundary,
        rootEntity: DioramaEntity
    ) {
        guard let style = configuration.buildings else { return }

        // Cover the pan margin as well as the chunk, so an ordinary drag slides onto ground that
        // already has buildings on it. They are extruded once and never re-cut, so this is the only
        // chance to fetch the ring.
        let margin = configuration.maximumPanOffset
        let lo = boundary.minCorner - margin
        let hi = boundary.minCorner + boundary.extent + margin
        let anchor = heightField.anchor
        let corners = [
            anchor.coordinate(forDioramaX: Double(lo.x), z: Double(lo.y)),
            anchor.coordinate(forDioramaX: Double(hi.x), z: Double(hi.y))
        ]
        // Z counts southward in tile space, so the corners come back with latitude inverted.
        let south = min(corners[0].latitude, corners[1].latitude)
        let north = max(corners[0].latitude, corners[1].latitude)
        let west = min(corners[0].longitude, corners[1].longitude)
        let east = max(corners[0].longitude, corners[1].longitude)

        let provider = OSMBuildingProvider(
            maximumBuildings: style.maximumBuildings,
            defaultHeightMeters: style.defaultHeightMeters,
            metersPerLevel: style.metersPerLevel
        )

        buildingsTask?.cancel()
        buildingsTask = Task { [logger] in
            let started = ContinuousClock.now
            let footprints: [BuildingFootprint]
            do {
                footprints = try await provider.fetchBuildings(
                    south: south, west: west, north: north, east: east
                )
            } catch {
                // A missing prototype layer is not a reason to fail a diorama that already renders.
                logger.error("Could not fetch buildings: \(error.localizedDescription)")
                return
            }
            guard !Task.isCancelled else { return }

            let fetched = ContinuousClock.now
            let result = BuildingExtruder.extrude(
                footprints: footprints,
                heightField: heightField,
                boundary: boundary,
                style: style
            )
            guard !Task.isCancelled, !result.mesh.isEmpty else { return }

            let entity = BuildingsEntity(style: style)
            entity.update(with: result.mesh, buildingCount: result.kept)
            entity.setPanOffset(self.panOffset)
            rootEntity.setBuildings(entity)

            let finished = ContinuousClock.now
            logger.info("""
                Stood \(result.kept) buildings on the chunk: fetch \
                \(String(format: "%.0f", (fetched - started).milliseconds)) ms, extrude \
                \(String(format: "%.0f", (finished - fetched).milliseconds)) ms
                """)
        }
    }

    /// Tiles of ground kept beyond the chunk, from the margin the configuration asks for.
    ///
    /// At least one either way: a chunk with no ring at all would fetch on every step.
    private static func marginTiles(meters: Float, perTile: Double) -> Int {
        guard perTile > 0 else { return 1 }
        return max(1, Int((Double(meters) / perTile).rounded(.up)))
    }

    /// The parts of the sampler that survive a roll, so only its grids have to be replaced.
    private struct SamplerTemplate {
        let zoom: Int
        let anchor: TerrainAnchor
        let exaggeration: Float
        let globalMinElev: Float
    }

    private var samplerTemplate: SamplerTemplate?

    private func setElevationSampler(grids: [(x: Int, y: Int, grid: ElevationGrid)]) {
        guard let template = samplerTemplate else { return }
        elevationSampler = ElevationSampler(
            grids: grids.map(\.grid),
            tilePositions: grids.map { (x: $0.x, y: $0.y) },
            zoom: template.zoom,
            center: configuration.center,
            radiusMeters: configuration.terrainFetchRadiusMeters,
            physicalDiameter: configuration.terrainRegionExtent.x,
            exaggeration: template.exaggeration,
            globalMinElev: template.globalMinElev,
            anchor: template.anchor
        )
        elevationSampler?.panOffset = panOffset
    }

    // MARK: - Photorealistic 3D Tiles Pipeline

    /// Loads OGC 3D Tiles content (Google Photorealistic, Cesium ion).
    private func loadPhotorealisticPipeline(
        provider: any Tiles3DProvider,
        style: Tiles3DStyle,
        into rootEntity: DioramaEntity
    ) async throws {
        let tiles3DEntity = try await Tiles3DEntity(
            provider: provider,
            center: configuration.center,
            radiusMeters: configuration.radiusMeters,
            physicalDiameter: configuration.physicalDiameter,
            boundary: configuration.boundary,
            style: style,
            panRange: configuration.panRange
        )
        rootEntity.setTiles3D(tiles3DEntity)
    }

    // MARK: - Panning

    /// How far the terrain has slid beneath the chunk's fixed outline, in diorama meters.
    public private(set) var panOffset: SIMD2<Float> = .zero

    /// How far the terrain can slide before it reaches ground that was not fetched up front.
    ///
    /// Both pipelines roll past this rather than stopping at it, so it reads as the margin held in
    /// reserve rather than a limit — the frontier moves with the ground. A terrain chunk fetches
    /// more tiles; a photorealistic model carries its cull column along with the outline and streams
    /// what the column now covers.
    public var maximumPanOffset: SIMD2<Float> {
        configuration.maximumPanOffset
    }

    /// Slides the terrain beneath the chunk's outline by a delta.
    ///
    /// - Parameter delta: Movement in diorama meters.
    public func pan(by delta: SIMD2<Float>) {
        setPanOffset(panOffset + delta)
    }

    /// Slides the terrain to an absolute offset.
    ///
    /// The chunk keeps its shape and position; only the ground beneath it moves. Markers and
    /// polylines are repositioned so they stay attached to the terrain they sit on.
    ///
    /// Neither pipeline is bounded in the long run — pan far enough and the ground under the chunk
    /// is somewhere else entirely. A terrain chunk rolls new tiles in as the offset grows; a
    /// photorealistic model carries its cull column with the outline, so it streams ground ahead of
    /// the drag and drops what is left behind.
    ///
    /// What bounds both moment to moment is the ground actually in hand: the offset stops at the
    /// edge of what has arrived and moves again as soon as more does. Letting it run ahead is what
    /// produces a jump — on the raster path the border smears and then snaps into place when the
    /// roll lands, and on the photorealistic path the outline stands over nothing, so the datum the
    /// tray and the cut wall are measured from moves the moment tiles reach it.
    ///
    /// That bound only ever refuses movement; it never produces any. Nothing here moves the terrain
    /// except the caller's own offset, which is what keeps the ground still once the finger lifts.
    ///
    /// - Parameter offset: The target offset in diorama meters.
    public func setPanOffset(_ offset: SIMD2<Float>) {
        guard configuration.panRange > 0 else { return }

        let target: SIMD2<Float>
        if let state = rolling {
            target = state.roller.clamp(offset, from: panOffset, within: state.window)

            // The chunk standing outside its own limits is the case an absolute clamp turns into a
            // jump, so it is worth naming when it happens rather than inferring it after the fact.
            let limits = state.roller.panLimits(within: state.window)
            let current = panOffset
            if simd_clamp(current, limits.low, limits.high) != current {
                logger.debug(
                    """
                    Pan offset is outside the loaded window: at \
                    \(current.x, format: .fixed(precision: 4)), \
                    \(current.y, format: .fixed(precision: 4)) against \
                    \(limits.low.x, format: .fixed(precision: 4))...\
                    \(limits.high.x, format: .fixed(precision: 4)), \
                    \(limits.low.y, format: .fixed(precision: 4))...\
                    \(limits.high.y, format: .fixed(precision: 4)); holding rather than pulling back
                    """
                )
            }
        } else if let tiles3D = (dioramaEntity as? DioramaEntity)?.tiles3D, tiles3D.canPan {
            target = tiles3D.clampPanOffset(offset)
        } else {
            let limit = configuration.maximumPanOffset
            target = simd_clamp(offset, -limit, limit)
        }
        // The frontier is invisible on screen — the ground simply stops following the finger — so
        // it is worth saying out loud which of the two is happening when a pan feels wrong.
        if target != offset {
            logger.debug(
                """
                Pan held at the frontier: asked \(offset.x, format: .fixed(precision: 4)), \
                \(offset.y, format: .fixed(precision: 4)); gave \
                \(target.x, format: .fixed(precision: 4)), \(target.y, format: .fixed(precision: 4))
                """
            )
        }
        guard target != panOffset else { return }

        panOffset = target
        elevationSampler?.panOffset = target

        // Split, because the two halves of a pan step are paid for differently: the resample is
        // fixed by the chunk's vertex count, while an effect's cost rides on what it traces. Logging
        // one total would hide which of them a slow pan is.
        let started = ContinuousClock.now
        (dioramaEntity as? DioramaEntity)?.terrain?.setPanOffset(target)
        (dioramaEntity as? DioramaEntity)?.tiles3D?.setPanOffset(target)
        // Buildings are anchored to geography like the content below, but they are geometry rather
        // than placed entities, so they ride one transform instead of being repositioned.
        (dioramaEntity as? DioramaEntity)?.buildings?.setPanOffset(target)
        let resampled = ContinuousClock.now
        refreshEffect()
        let finished = ContinuousClock.now
        if effectPass != nil {
            logger.debug("""
                Pan step: resample \
                \(String(format: "%.1f", (resampled - started).milliseconds)) ms, \
                effect \(String(format: "%.1f", (finished - resampled).milliseconds)) ms
                """)
        }

        // Content is anchored to geography, so it has to move with the ground.
        applyContent(appliedContent)

        rollTerrainIfNeeded()
    }

    // MARK: - Rolling Fetch

    /// What a rolling chunk holds between rolls.
    private struct TerrainRollState {
        let roller: TerrainRoller
        var tiles: TerrainTileSet
        var window: TerrainTileWindow
    }

    private var rolling: TerrainRollState?
    private var rollTask: Task<Void, Never>?

    /// Fetches more ground once the chunk comes within the margin ring of what is loaded.
    ///
    /// This runs ahead of the frontier rather than at it: the window a pan offset requires is the
    /// chunk's footprint *plus* the margin, so the fetch starts while there is still ground to slide
    /// onto and the pan usually never notices. When a drag does outrun it the offset holds at the
    /// frontier instead of smearing, so the cost is a pause rather than a jump. One roll runs at a
    /// time and re-checks the offset when it finishes, because the offset it started from is stale
    /// by then.
    private func rollTerrainIfNeeded() {
        guard rollTask == nil, let state = rolling else { return }
        guard !state.window.contains(state.roller.window(forPanOffset: panOffset)) else { return }

        rollTask = Task { [self] in
            defer { rollTask = nil }
            while let state = rolling, !Task.isCancelled {
                let required = state.roller.window(forPanOffset: panOffset)
                guard !state.window.contains(required) else { return }

                guard let roll = await state.roller.load(window: required, have: state.tiles) else {
                    logger.warning("Terrain roll loaded nothing; staying on the ground already held")
                    return
                }
                guard !Task.isCancelled, rolling != nil else { return }

                // The window is what the clamp lets the chunk pan across, so it may only advance
                // once the ground behind it is actually on screen. Recording a roll that was
                // declined would licence panning onto terrain nothing ever drew.
                guard applyRoll(roll) else { return }
                rolling?.tiles = roll.tiles
                rolling?.window = roll.window
            }
        }
    }

    /// Swaps in the ground a roll loaded, reporting whether it could.
    @discardableResult
    private func applyRoll(_ roll: TerrainRoll) -> Bool {
        // The ground and its picture share one mapping, so they have to move together. `setTerrain`
        // resamples the surface's texture coordinates against the new window whether or not a new
        // texture comes with them, so applying a roll whose imagery did not composite would leave
        // the previous window's pixels stretched over the new window's coordinates — the picture
        // visibly sliding off the terrain it belongs to, and staying wrong until some later roll
        // happened to succeed. Declining the roll keeps the chunk on ground it can still draw.
        guard let image = roll.imagery,
              let material = try? DioramaMaterials.satelliteMaterial(from: image) else {
            logger.debug(
                """
                Declined a roll to tiles x \(roll.window.minX)...\(roll.window.maxX), \
                y \(roll.window.minY)...\(roll.window.maxY): its imagery did not composite
                """
            )
            return false
        }

        (dioramaEntity as? DioramaEntity)?.terrain?.setTerrain(
            roll.heightField,
            surfaceMaterial: material
        )
        // New ground means new heights, and the roll has just handed the chunk a fresh surface
        // material — which paints the imagery back over a chunk the effect had darkened.
        reapplyEffect()

        // The sampler reads the same ground, so it moves with it or markers drift off the terrain.
        setElevationSampler(
            grids: roll.heightField.tilePositions.enumerated().map { index, position in
                (x: position.x, y: position.y, grid: roll.heightField.grids[index])
            }
        )
        applyContent(appliedContent)

        logger.debug(
            """
            Rolled terrain to tiles x \(roll.window.minX)...\(roll.window.maxX), \
            y \(roll.window.minY)...\(roll.window.maxY)
            """
        )
        return true
    }

    // MARK: - Content Application

    /// The content most recently applied, retained so panning can reposition it.
    private var appliedContent: DioramaContentGroup?

    /// Materializes diorama content (markers, polylines) as 3D entities on the loaded diorama.
    ///
    /// Call this after `load()` completes. Each marker becomes a `MarkerEntity` positioned at the
    /// correct terrain height. Each polyline becomes a flat ribbon mesh following the terrain surface.
    ///
    /// - Parameter content: The content group to apply, or `nil` to skip.
    public func applyContent(_ content: DioramaContentGroup?) {
        appliedContent = content
        guard let content, let rootEntity = dioramaEntity as? DioramaEntity else { return }

        let proxy = DioramaProxy(
            configuration: configuration,
            elevationSampler: elevationSampler
        )

        rootEntity.applyContent(
            content,
            using: proxy,
            physicalDiameter: configuration.physicalDiameter
        )
        routePreviewEntity = rootEntity.routePreview
    }
}
