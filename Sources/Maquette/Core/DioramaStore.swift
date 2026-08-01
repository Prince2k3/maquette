import CoreGraphics
import Foundation
import RealityKit
import os

/// Loading state for the diorama.
public enum DioramaLoadingState: Sendable, Equatable {
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
final class DioramaStore {
    /// Current loading state.
    public private(set) var loadingState: DioramaLoadingState = .idle

    /// The credit line the photorealistic tiles on screen require, or `nil` for other imagery.
    ///
    /// The views draw this whenever it is present; showing the sources credited by the tiles in
    /// view is a condition of the tile services' terms.
    public private(set) var tilesAttribution: String?

    /// The root diorama entity, available once loading completes.
    public private(set) var dioramaEntity: Entity?

    /// The active configuration.
    public var configuration: DioramaConfiguration

    /// How geographic coordinates map onto this diorama, available once its geometry exists.
    ///
    /// The pipeline that built the geometry chooses it, so everything placed afterwards — markers,
    /// routes, overlays — lands in the frame the geometry is actually in rather than in an
    /// approximation of it.
    public private(set) var projection: (any DioramaProjection)?

    /// The active route preview entity, if one was applied via content.
    public private(set) var routePreviewEntity: RoutePreviewEntity?

    /// The globe the chunk zooms out into, once ``loadGlobe(style:)`` has fetched it.
    ///
    /// Deliberately *not* a child of the diorama entity, and not cleared by ``reset()``. Zooming
    /// back in somewhere else tears the chunk down and builds a new one, and the globe is what the
    /// user is looking at while that happens — parented to the chunk it would be destroyed at the
    /// exact moment it is doing its job. It also outlives the chunk conceptually: the world does not
    /// depend on which part of it is on the table.
    public private(set) var globe: GlobeEntity?

    /// How much of a streaming presentation has arrived, or `nil` if this one does not stream.
    ///
    /// Computed rather than stored so it stays live: the counters belong to the tile manager, and
    /// reading them here is what registers a SwiftUI view for their updates.
    public var streamingProgress: DioramaStreamingProgress? {
        (dioramaEntity as? DioramaEntity)?.tiles3D?.streamingProgress
    }

    private let tileCache = TileCache()
    private let logger = Logger(maquette: "DioramaStore")

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
        tilesAttribution = nil
        rollTask?.cancel()
        rollTask = nil
        buildingsTask?.cancel()
        buildingsTask = nil
        buildingsCutTask?.cancel()
        buildingsCutTask = nil
        buildingsFetchTask?.cancel()
        buildingsFetchTask = nil
        relevelTask?.cancel()
        relevelTask = nil
        buildings = nil
        rolling = nil
        samplerTemplate = nil
        terrainField = nil
        effectPass = nil
        loadingState = .idle
        dioramaEntity = nil
        projection = nil
        routePreviewEntity = nil
        panOffset = .zero
        groundScale = 1
    }

    // MARK: - The Globe

    /// Fetches the world and docks it under the chunk, ready for the zoom-out handoff.
    ///
    /// Idempotent and cheap to call again: a globe already built is left alone, so a view may ask
    /// for it on every appearance. The imagery comes from the configuration's own
    /// ``ImagerySource`` through the same tile cache the chunk uses, so a globe and the chunk
    /// standing on it are made of the same pictures.
    ///
    /// A failure is logged and leaves ``globe`` nil rather than throwing: the world is an addition
    /// to a diorama that already renders, and taking the whole view down because a low-zoom tile
    /// server was unreachable would be the wrong trade.
    public func loadGlobe(style: GlobeTransitionStyle) async {
        guard globe == nil else { return }
        do {
            let image = try await GlobeEntity.fetchWorldImage(
                provider: imageryProvider,
                cache: tileCache,
                zoom: style.imageryZoom
            )
            let entity = try GlobeEntity(
                radius: style.radius,
                worldImage: image,
                rows: style.rows,
                columns: style.columns
            )
            globe = entity
            dockGlobe()
            // The effect may already be on — the globe fetch races the chunk's own load, and the
            // effect is applied when the chunk lands. Whichever finishes second styles the world.
            styleGlobeForEffect()
            logger.info("Globe ready at radius \(style.radius)")
        } catch {
            logger.error("Globe could not be loaded: \(error.localizedDescription)")
        }
    }

    /// Puts the globe under the chunk's current centre.
    ///
    /// Called whenever that centre changes, which is what keeps the handoff reversible: the point
    /// the globe presents is always the ground the chunk is cut from. It is the caller's job to pick
    /// *when* — see ``relocate(to:)``.
    public func dockGlobe() {
        applyDock(at: Coordinate(configuration.center))
    }

    /// Spins the world under the camera, by an offset measured on the ground in metres.
    ///
    /// The globe is looked at from directly overhead — see ``GlobeTransition/cameraElevation()`` —
    /// so the coordinate it is docked at is the coordinate at the centre of the screen. Spinning it
    /// is therefore the same operation as walking that coordinate, and the dock is *recomputed*
    /// from where the walk lands rather than accumulating a rotation on top of the old one. Two
    /// things follow, both of which an accumulated quaternion gets wrong: north stays at −Z however
    /// far the world has been spun, so the map never rolls; and where the chunk will be cut from is
    /// readable straight off ``globeDock``.
    ///
    /// - Parameters:
    ///   - east: Ground distance to move the centre eastward, in metres. Negative for west.
    ///   - north: Ground distance to move the centre northward, in metres. Negative for south.
    public func steerGlobe(east: Double, north: Double) {
        guard let dock = globeDock else { return }
        guard east != 0 || north != 0 else { return }
        applyDock(at: Self.steered(dock.coordinate, east: east, north: north))
    }

    /// Where a coordinate lands when the map under it is dragged east and north.
    ///
    /// The two legs are walked *separately*, which is the difference between steering a north-up map
    /// and flying a course. A single great circle on the resulting bearing is the shorter path and
    /// the wrong one here: leaving on a bearing of 90° is not the same as staying on the parallel,
    /// and the gap is not academic at the distances one screen point is worth on a globe — twenty
    /// steps of 280 km due east from 45°N arrive 1.09° south of where they started, 121 km of
    /// unasked-for drift from a drag that never left the horizontal.
    ///
    /// So north is walked along the meridian and east along the parallel. The meridian *is* a great
    /// circle, so the closed form below is exactly ``Turf/destination(from:meters:bearing:)`` on a
    /// bearing of 0 — with one difference that is the point of writing it out: Turf carries on over
    /// the pole and comes down the far side with the longitude flipped by 180°, which on screen is
    /// the entire world spinning half a turn mid-drag and then travelling backwards. The clamp stops
    /// the walk at the edge instead.
    ///
    /// It stops at **Mercator's** limit rather than at the pole because that is where the data
    /// stops: no tile covers the last five degrees, so the globe wears a smeared cap there and a
    /// chunk relocated into it would be cut from imagery that does not exist.
    nonisolated static func steered(_ origin: Coordinate, east: Double, north: Double) -> Coordinate {
        let limit = GlobeGeometry.mercatorLimitDegrees
        let degreesPerMeter = 180 / (.pi * Turf.earthRadiusMeters)
        let latitude = min(max(origin.latitude + north * degreesPerMeter, -limit), limit)

        // A parallel shrinks towards the poles, so the same ground distance is more longitude the
        // further north it is walked. The clamp above is what keeps this from dividing by nothing.
        let parallelRadius = Turf.earthRadiusMeters * cos(latitude * .pi / 180)
        let longitude = Turf.normalizedLongitude(origin.longitude + east * 180 / (.pi * parallelRadius))
        return Coordinate(longitude: longitude, latitude: latitude, altitude: origin.altitude)
    }

    /// Draws the globe at a fraction of its full size, pivoted on the docked coordinate.
    ///
    /// This is what the handoff grows through — see ``GlobeTransition/globeScale`` for why the leg
    /// needs it and ``GlobeDock/matrix(scale:)`` for why the pivot cannot be the sphere's centre. It
    /// only ever moves during a leg; anything that reads a coordinate off the globe runs settled,
    /// where it is 1.
    ///
    /// Floored rather than clamped to zero, because a scale of zero is a singular transform and
    /// RealityKit is entitled to do anything at all with one. At this size the globe is a few
    /// thousandths of a diorama metre across and fully transparent besides.
    public func setGlobeScale(_ scale: Float) {
        let scale = max(scale, 0.001)
        guard scale != globeScale else { return }
        globeScale = scale
        guard let dock = globeDock else { return }
        globe?.transform = Transform(matrix: dock.matrix(scale: scale))
    }

    /// The fraction of its full size the globe is currently drawn at.
    public private(set) var globeScale: Float = 1

    private func applyDock(at coordinate: Coordinate) {
        guard let globe else { return }
        let dock = GlobeDock(coordinate: coordinate, radius: globe.radius)
        globe.transform = Transform(matrix: dock.matrix(scale: globeScale))
        globeDock = dock
    }

    /// The dock the globe is currently standing in, for a caller reading a coordinate off it.
    ///
    /// Recorded at the moment it is applied rather than derived from ``configuration``, because the
    /// two are deliberately allowed to disagree: a relocate moves the centre immediately and the
    /// globe is not re-docked until the transition says it may. A dock computed from the live centre
    /// would then describe a rotation the globe has not performed, and a coordinate read through it
    /// would land somewhere the user never pointed at.
    public private(set) var globeDock: GlobeDock?

    /// Rebuilds the chunk at a new centre, leaving everything else about the configuration alone.
    ///
    /// This is the second half of the globe handoff: the user spins the world, pinches back in, and
    /// the chunk that reappears is cut from wherever they left facing. It is a full teardown and
    /// reload rather than an in-place edit, because a chunk's boundary, anchor, height field,
    /// imagery and projection are all derived from the centre — there is nothing left of the old
    /// one worth keeping.
    ///
    /// The globe survives it deliberately, so the world stays on screen for the whole rebuild — and
    /// it is pointedly **not** re-docked here. Re-docking rotates the entire world under a camera
    /// that has not moved, and a relocate is issued the moment the pinch starts coming back in, with
    /// the globe still at full opacity. The caller docks instead, at the one moment the globe is
    /// wholly invisible; see ``GlobeTransition``.
    ///
    /// **The ground zoom survives it too, and that is what makes the handoff reversible.** A pinch
    /// out is a journey the user takes in steps — the map widens, re-levels, widens again, and the
    /// globe takes over at the far end — so the chunk that comes back has to be cut at the breadth
    /// they left at, and the way home is the same steps in reverse. ``load()`` builds every chunk at
    /// its configuration's own radius, which for a departure from the ceiling is a factor of a couple
    /// of hundred too narrow: the user lands on a five-kilometre chunk of somewhere they were
    /// looking at a thousand kilometres of, and a further pinch in — the only gesture that makes
    /// sense there — can only go the wrong way.
    public func relocate(to coordinate: Coordinate) async {
        // Captured before `reset()`, which puts the scale back to 1 along with everything else.
        let departureScale = groundScale
        logger.info("""
            Relocating to \(coordinate.latitude, format: .fixed(precision: 4)), \
            \(coordinate.longitude, format: .fixed(precision: 4)) \
            at ground scale \(departureScale, format: .fixed(precision: 3))
            """)
        reset()
        configuration.center = coordinate.clLocationCoordinate
        await load()
        await restoreGroundScale(departureScale)
    }

    /// Tears down and rebuilds against a new configuration, for a live style or region change.
    ///
    /// Unlike ``relocate(to:)`` this does not carry the ground scale across: a new radius or style
    /// is a new diorama, and it comes up the way a fresh load does.
    public func reload(configuration newConfiguration: DioramaConfiguration) async {
        reset()
        configuration = newConfiguration
        await load()
    }

    /// Re-widens a freshly loaded chunk to the ground zoom the one it replaced was showing.
    ///
    /// Two things here are deliberate and both fail quietly if they are dropped.
    ///
    /// **The scale is restored rather than the tile level**, because the level is derived and the
    /// scale is not: ``groundScaleLimits`` is measured from `baseAnchor.zoom`, which has to stay the
    /// level the chunk *loaded* at or the range collapses and the ground can never be zoomed again.
    /// Handing `load()` a coarse zoom to fetch at directly would be cheaper — it would save the fine
    /// fetch this throws away — but it would also generate the chunk's earth mass against terrain
    /// that has already been flattened by the scale, so the block would come back thinner than it
    /// departed. Going through ``setGroundScale(_:)`` means the thickness rule sees the same
    /// generated relief a chunk loaded here directly would have.
    ///
    /// **The re-level is awaited**, because the zoom itself fetches nothing: it stretches the tiles
    /// in hand, and stretching a fine mosaic by a couple of hundred is not something to hand back
    /// to the user. The caller holds the globe over this whole call, so the wait costs a still frame
    /// rather than a visible one.
    private func restoreGroundScale(_ scale: Float) async {
        guard abs(scale - 1) > 1e-4, canZoomGround else { return }
        setGroundScale(scale)
        await relevelTask?.value
    }

    /// The tile provider the configuration's imagery source names.
    private var imageryProvider: any TileProvider {
        switch configuration.imagerySource {
        case .esriSatellite:
            SatelliteTileProvider()
        case .mapTilerSatellite(let apiKey):
            MapTilerSatelliteProvider(apiKey: apiKey)
        }
    }

    // MARK: - Effects

    /// The visual effect painted over the built diorama.
    public private(set) var effect: DioramaEffect = .none

    private var effectPass: (any DioramaEffectPass)?

    /// The composited mosaic currently painted on the chunk.
    ///
    /// Kept because an effect that restyles the imagery has to read it, and the `TextureResource` it
    /// was uploaded as cannot be read back. Replaced when a roll lands, so the picture an effect
    /// works from is the window the chunk is actually showing.
    private var mosaic: CGImage?

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

    // MARK: - Buildings

    /// Whether the extruded buildings are drawn. `false` for a diorama that asked for none.
    ///
    /// Reads through the configuration rather than shadowing it, so there is one answer to the
    /// question however it is asked.
    public var buildingsVisible: Bool { configuration.buildings?.isVisible ?? false }

    /// Shows or hides the buildings, keeping everything that was fetched for them.
    ///
    /// The same shape as ``setEffect(_:)`` and for the same reason: this is a restyle of the finished
    /// scene, so it never queries a provider or rebuilds a mesh, and setting it before the buildings
    /// have arrived is fine — the entity is created with the configuration's own flag.
    ///
    /// Turning them back on is where the work is. A hidden layer stands its pan work down, so the
    /// selection on screen and the ground fetched for it are both as stale as the pan that happened
    /// while it was off; both are brought back up to date here.
    public func setBuildingsVisible(_ visible: Bool) {
        guard configuration.buildings != nil, visible != buildingsVisible else { return }
        configuration.buildings?.isVisible = visible
        (dioramaEntity as? DioramaEntity)?.buildings?.isVisible = visible
        guard visible else { return }
        recutBuildingsIfNeeded()
        refetchBuildingsIfNeeded()
    }

    private var effectContext: DioramaEffectContext {
        DioramaEffectContext(
            boundary: configuration.boundary,
            elevationScale: configuration.geographicScale * (samplerTemplate?.exaggeration ?? 1),
            baselineElevation: samplerTemplate?.baselineElevation ?? 0,
            imagery: mosaic
        )
    }

    private func rebuildEffect() {
        guard let root = dioramaEntity as? DioramaEntity else { return }
        effectPass?.revert(from: root)
        effectPass = effect.makePass()
        effectPass?.apply(to: root, context: effectContext)
        styleGlobeForEffect()
    }

    /// Dresses the globe in the active effect's imagery treatment, or back in photography.
    ///
    /// The handoff dissolves the chunk into the globe, and an inked chunk departing from a
    /// photographic world breaks the treatment at exactly the moment everything else is moving.
    /// Called when the effect changes and when the globe finishes loading — whichever comes
    /// second does the styling, since either can. A pass with no image-level statement returns
    /// nil and the mosaic stays photographic.
    private func styleGlobeForEffect() {
        guard let globe else { return }
        if let pass = effectPass, let world = globe.worldImage,
           let styled = pass.globeImagery(from: world) {
            globe.applyEffectImagery(styled, opacity: pass.globeOpacity)
        } else {
            globe.restoreImagery()
        }
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

        let satelliteProvider: any TileProvider = imageryProvider

        var terrainGrids: [(x: Int, y: Int, grid: ElevationGrid)] = []
        var satelliteImages: [(x: Int, y: Int, data: Data)] = []

        for tile in tiles {
            // The window keeps counting east past the antimeridian so it stays a rectangle; only the
            // request folds back into the range a provider will accept. The grid keeps the unwrapped
            // column, which is what the anchor and the height field are laid out against.
            let requestX = TileMath.wrappedColumn(tile.x, zoom: zoom)
            async let terrainData = tileCache.cachedOrFetch(
                x: requestX, y: tile.y, zoom: zoom,
                provider: terrainProvider
            )
            async let satelliteData = tileCache.cachedOrFetch(
                x: requestX, y: tile.y, zoom: zoom,
                provider: satelliteProvider
            )

            let tData = try await terrainData
            let sData = try await satelliteData

            let grid = try TerrariumDecoder.decodeElevation(from: tData)
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
        let globalMinElev = heightField.baselineElevation

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

        // Composite the mosaic, then upload it — in that order, and through the same path whether it
        // is one tile or many, because the image is kept as well as uploaded and an effect that
        // restyles the imagery needs it whatever the region's size worked out to.
        let terrainMaterial: RealityKit.Material
        if let minX = satelliteImages.map(\.x).min(),
           let minY = satelliteImages.map(\.y).min(),
           let maxX = satelliteImages.map(\.x).max(),
           let maxY = satelliteImages.map(\.y).max(),
           let composited = try? DioramaMaterials.compositeSatelliteImage(
               tiles: satelliteImages,
               minX: minX,
               minY: minY,
               tilesWide: maxX - minX + 1,
               tilesTall: maxY - minY + 1
           ),
           let material = try? DioramaMaterials.satelliteMaterial(from: composited) {
            mosaic = composited
            terrainMaterial = material
        } else {
            mosaic = nil
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

        // Fill the sea-level ground, where there is land for it to meet. A region wholly at or below
        // sea level gets none: the plane would cover the whole top face and the chunk would come back
        // as a blue lid with its terrain sealed underneath.
        if WaterPlaneEntity.belongsInRegion(
            minElevation: globalMinElev,
            maxElevation: heightField.maxElevation
        ), exaggeration > 0 {
            if let waterEntity = WaterPlaneEntity.generate(
                boundary: boundary,
                baselineElevation: globalMinElev,
                elevationScale: elevationScale
            ) {
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
            elevationScale: elevationScale,
            baselineElevation: globalMinElev,
            baseAnchor: anchor,
            baseElevationScale: elevationScale,
            // Measured through the height field the chunk was generated from, at pan offset zero,
            // so the rim is the one the solid actually has rather than the rim of some other
            // sampling of the same ground. Frozen from here on.
            datum: GroundDatum.measured(boundary: boundary, heightField: heightField)
        )
        groundScale = 1
        terrainField = heightField
        setTerrainProjection(grids: terrainGrids)

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
            tileGeneration += 1
        }

        startBuildingsFetch(heightField: heightField, boundary: boundary, rootEntity: rootEntity)
    }

    // MARK: - Buildings

    private var buildingsTask: Task<Void, Never>?

    /// What standing buildings on a chunk that pans needs to keep between selections.
    private struct BuildingsState {
        let style: BuildingStyle
        /// Where more footprints come from when the chunk pans off the ones in hand.
        let provider: any BuildingProvider
        /// Every footprint held, in diorama space — including the margin ring, which is outside the
        /// outline at rest and is the whole reason a pan has anything new to show. Kept because both
        /// a roll and a fetch make the arena stale and it has to be built again from these.
        var footprints: [BuildingExtruder.PlanarFootprint]
        /// All of them extruded, once. A pan selects out of this rather than rebuilding it.
        var blocks: BuildingExtruder.Blocks
        /// The ground `footprints` covers. Slides with the chunk, one strip at a time.
        var covered: GroundBox
        let boundary: DioramaBoundary
        /// The ground the blocks stand on. A roll replaces it.
        var heightField: TerrainHeightField
        /// The offset the drawn selection was made for.
        var cutOffset: SIMD2<Float>
        /// Set when the arena no longer describes `footprints` standing on `heightField` — either
        /// because the ground moved under them or because a fetch changed which ones are held.
        var blocksStale = false
        /// Bumped whenever `footprints` or `heightField` is replaced.
        ///
        /// A rebuild takes tens of milliseconds off the main actor, and a fetch or a roll can land
        /// inside that window. Without a generation the rebuild would come back and install an arena
        /// for inputs that no longer exist, clearing `blocksStale` as it went — so the new footprints
        /// would sit in the state, unextruded, until something else happened to invalidate it.
        var generation = 0
        /// How far the chunk may slide before it is worth selecting again.
        let threshold: Float
    }

    private var buildings: BuildingsState?
    private var buildingsCutTask: Task<Void, Never>?
    private var buildingsFetchTask: Task<Void, Never>?

    /// Fraction of the pan ring the chunk may spend before more buildings are asked for.
    ///
    /// Hysteresis, and the reason it is needed here but not for terrain: tiles are chunky enough that
    /// a rolling window quantises the question on its own, while a building region is continuous and
    /// would otherwise issue a query for every millimetre of drag. Half the ring means an ordinary
    /// drag fetches once and still has the other half in hand while the answer is out.
    private static let buildingsRefetchTrigger: Float = 0.5

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
        // already has buildings on it rather than waiting for a query.
        let covered = GroundBox(
            lo: boundary.minCorner,
            hi: boundary.minCorner + boundary.extent
        ).expanded(by: configuration.maximumPanOffset)
        let box = covered.geographicBounds(anchor: heightField.anchor)

        let provider = style.source.makeProvider(style: style)

        buildingsTask?.cancel()
        buildingsTask = Task { [logger] in
            let started = ContinuousClock.now
            let footprints: [BuildingFootprint]
            do {
                footprints = try await provider.fetchBuildings(
                    south: box.south, west: box.west, north: box.north, east: box.east
                )
            } catch {
                // A missing prototype layer is not a reason to fail a diorama that already renders.
                logger.error("Could not fetch buildings: \(error.localizedDescription)")
                return
            }
            guard !Task.isCancelled else { return }

            let fetched = ContinuousClock.now
            // Awaited rather than called: both of these are `@concurrent`, so this hands the whole
            // scalar loop to the cooperative pool and comes back to the main actor holding the
            // finished mesh. Structured, so cancelling `buildingsTask` still reaches into the loop.
            let planar = await BuildingExtruder.project(footprints, anchor: heightField.anchor)
            let blocks = await BuildingExtruder.build(
                footprints: planar,
                heightField: heightField,
                style: style
            )
            let offset = self.panOffset
            let selection = await BuildingExtruder.select(
                from: blocks,
                boundary: boundary,
                panOffset: offset
            )
            guard !Task.isCancelled else { return }

            self.buildings = BuildingsState(
                style: style,
                provider: provider,
                footprints: planar,
                blocks: blocks,
                covered: covered,
                boundary: boundary,
                heightField: heightField,
                cutOffset: offset,
                // A building is a few millimetres across at diorama scale, so the outline has to
                // slide by something on that order before the cut it made is visibly stale. Tied to
                // the chunk rather than fixed, because "a few millimetres" is only true at the size
                // chunks usually are.
                threshold: max(boundary.extent.x, boundary.extent.y) * 0.004
            )

            let entity = BuildingsEntity(style: style)
            entity.install(blocks)
            entity.show(selection)
            entity.setPanOffset(offset)
            rootEntity.setBuildings(entity)
            // The offset may have moved while the fetch was out, and this is the first selection, so
            // nothing else would notice — including that the chunk may already be standing off the
            // ring this fetch covered.
            recutBuildingsIfNeeded()
            refetchBuildingsIfNeeded()

            let finished = ContinuousClock.now
            logger.info("""
                Stood \(selection.kept) buildings on the chunk, holding \(blocks.blocks.count) \
                extruded for the pan: fetch \
                \(String(format: "%.0f", (fetched - started).milliseconds)) ms, extrude \
                \(String(format: "%.0f", (finished - fetched).milliseconds)) ms
                """)
        }
    }

    /// Picks the buildings the outline covers again once the ground has slid far enough under it.
    ///
    /// Panning cannot be a transform alone. The mesh drawn at rest holds only the footprints inside
    /// the outline *then*, so sliding it bodily carries those past the rim on the trailing side and
    /// leaves the leading side empty — while the margin ring the fetch deliberately covers, which is
    /// the ground now arriving, would never be drawn at all. Selecting again is what turns that ring
    /// into visible geometry and takes the departed buildings away.
    ///
    /// A step is only ``BuildingExtruder/select(from:boundary:panOffset:)`` — a membership scan and a
    /// gather of index spans. Everything expensive happened once, at ``BuildingExtruder/build(footprints:heightField:style:)``:
    /// nothing about a block's geometry depends on the pan, so a step that re-extruded was doing the
    /// heaviest work in the library at drag rate, and in a debug build that is seconds per step.
    ///
    /// Two things do invalidate the arena: a roll, because `baseY` comes off the height field, and a
    /// fetch, because there are footprints in hand that are not in it. The old arena stays drawn
    /// while the new one is built, so the ground moves a moment before the blocks re-seat on it.
    ///
    /// Shaped like ``rollTerrainIfNeeded()`` and for the same reason: one runs at a time and re-reads
    /// the offset when it lands, because the offset it started from is stale by then. A drag can
    /// still outrun it — which is harmless here in a way it is not for terrain. Positions are in
    /// ground space and the entity's transform is current, so a stale selection is in exactly the
    /// right place and merely a little late at the rim.
    private func recutBuildingsIfNeeded() {
        guard buildingsCutTask == nil, let state = buildings, state.style.followsPan else { return }
        guard buildingsVisible, buildingsNeedCutting(state) else { return }

        buildingsCutTask = Task { [self] in
            defer { buildingsCutTask = nil }
            while let state = buildings, !Task.isCancelled, buildingsVisible,
                  buildingsNeedCutting(state) {
                let offset = panOffset
                let started = ContinuousClock.now

                var blocks = state.blocks
                if state.blocksStale {
                    blocks = await BuildingExtruder.build(
                        footprints: state.footprints,
                        heightField: state.heightField,
                        style: state.style
                    )
                }
                let selection = await BuildingExtruder.select(
                    from: blocks,
                    boundary: state.boundary,
                    panOffset: offset
                )
                guard !Task.isCancelled, buildings != nil else { return }
                // A fetch or a roll landing during the rebuild means this arena was built from
                // inputs the state no longer holds. Installing it would be wrong and clearing the
                // flag would be worse — the loop goes round again on the current ones instead.
                guard buildings?.generation == state.generation else { continue }

                let entity = (dioramaEntity as? DioramaEntity)?.buildings
                if state.blocksStale {
                    buildings?.blocks = blocks
                    entity?.install(blocks)
                }
                entity?.show(selection)
                buildings?.cutOffset = offset
                buildings?.blocksStale = false

                logger.debug("""
                    Drew \(selection.kept) buildings at \
                    \(offset.x, format: .fixed(precision: 4)), \
                    \(offset.y, format: .fixed(precision: 4)) in \
                    \(String(format: "%.2f", (ContinuousClock.now - started).milliseconds)) ms\
                    \(state.blocksStale ? " (re-extruded)" : "")
                    """)
            }
        }
    }

    private func buildingsNeedCutting(_ state: BuildingsState) -> Bool {
        state.blocksStale
            || simd_distance_squared(panOffset, state.cutOffset) > state.threshold * state.threshold
    }

    /// Fetches footprints for ground the chunk is panning onto.
    ///
    /// The selection can only draw what has been fetched, so without this a pan runs the buildings
    /// out at the edge of the initial ring while the terrain rolls happily onward — a downtown that
    /// simply stops, which reads as data missing rather than as a limit.
    ///
    /// Shaped like ``rollTerrainIfNeeded()``, and ahead of the frontier for the same reason: the
    /// trigger box is the outline plus *half* the ring, so the query goes out while there is still
    /// half a ring of buildings to slide onto. What arrives is only the difference —
    /// ``GroundBox/subtracting(_:)`` — because a query costs seconds against Overpass and asking it
    /// again for the city already in hand is the expensive way to learn nothing.
    ///
    /// The region is then *replaced* rather than accumulated: what falls outside the new one is
    /// dropped. Keeping it would grow the arena without bound along a long pan, and the arena is
    /// rebuilt whole every time the ground moves under it, so the cost of remembering a city already
    /// left behind is paid on every roll. The trade is that panning back across the seam fetches
    /// again.
    private func refetchBuildingsIfNeeded() {
        guard buildingsFetchTask == nil, let state = buildings, state.style.followsPan else { return }
        guard buildingsVisible, buildingsNeedFetching(state) else { return }

        buildingsFetchTask = Task { [self] in
            defer { buildingsFetchTask = nil }
            while let state = buildings, !Task.isCancelled, buildingsVisible,
                  buildingsNeedFetching(state) {
                let target = buildingsTarget(state)
                let anchor = state.heightField.anchor
                let started = ContinuousClock.now

                var fetched: [BuildingFootprint] = []
                for strip in target.subtracting(state.covered) {
                    let box = strip.geographicBounds(anchor: anchor)
                    do {
                        fetched += try await state.provider.fetchBuildings(
                            south: box.south, west: box.west, north: box.north, east: box.east
                        )
                    } catch {
                        // The ground already in hand still draws; the strip is asked for again on
                        // the next step, which is the same thing a failed terrain roll does.
                        logger.error("Could not fetch more buildings: \(error.localizedDescription)")
                        return
                    }
                }
                guard !Task.isCancelled, buildings != nil else { return }

                let planar = await BuildingExtruder.project(fetched, anchor: anchor)
                guard !Task.isCancelled, let state = buildings else { return }

                let footprints = BuildingExtruder.merge(
                    planar,
                    into: state.footprints,
                    covering: target,
                    alreadyHeld: state.covered
                )
                buildings?.footprints = footprints
                buildings?.covered = target
                buildings?.blocksStale = true
                buildings?.generation += 1
                recutBuildingsIfNeeded()

                logger.info("""
                    Fetched \(planar.count) more building footprints, holding \(footprints.count): \
                    \(String(format: "%.0f", (ContinuousClock.now - started).milliseconds)) ms
                    """)
            }
        }
    }

    /// The ground a fetch would cover: the outline where it stands now, plus the whole pan ring.
    private func buildingsTarget(_ state: BuildingsState) -> GroundBox {
        GroundBox(
            lo: state.boundary.minCorner + panOffset,
            hi: state.boundary.minCorner + state.boundary.extent + panOffset
        ).expanded(by: configuration.maximumPanOffset)
    }

    private func buildingsNeedFetching(_ state: BuildingsState) -> Bool {
        let outline = GroundBox(
            lo: state.boundary.minCorner + panOffset,
            hi: state.boundary.minCorner + state.boundary.extent + panOffset
        )
        let trigger = outline.expanded(
            by: configuration.maximumPanOffset * Self.buildingsRefetchTrigger
        )
        return !state.covered.contains(trigger)
    }


    /// Tiles of ground kept beyond the chunk, from the margin the configuration asks for.
    ///
    /// At least one either way: a chunk with no ring at all would fetch on every step.
    private static func marginTiles(meters: Float, perTile: Double) -> Int {
        guard perTile > 0 else { return 1 }
        return max(1, Int((Double(meters) / perTile).rounded(.up)))
    }

    /// The parts of the projection that survive a roll, so only its grids have to be replaced.
    ///
    /// The anchor and the baseline are exactly the two things a roll must not change — the anchor
    /// because it is what names which ground a diorama position refers to, and the baseline because
    /// re-measuring it against the new window is what makes the chunk bob.
    private struct SamplerTemplate {
        /// Tile level the resident grids are expressed at. Unchanged by a roll; moved by a ground
        /// zoom, once the mosaic has stretched far enough to want coarser tiles instead.
        var zoom: Int
        /// The mapping the resident grids are read through, at the ground zoom in force.
        var anchor: TerrainAnchor
        let exaggeration: Float
        /// Raw elevation meters to diorama meters, at the ground zoom in force.
        var elevationScale: Float
        /// The raw elevation sitting at diorama Y = 0, at the ground zoom in force.
        var baselineElevation: Float
        /// The mapping, the scale and the datum the chunk loaded at, so a ground zoom is *derived*
        /// from the scale rather than accumulated across steps. A pinch is hundreds of steps, and
        /// multiplying a mapping by a ratio each time would let the ground drift away from the scale
        /// it names.
        let baseAnchor: TerrainAnchor
        let baseElevationScale: Float
        /// What Y = 0 means at any ground scale, measured once at generation. See ``GroundDatum``
        /// for why a zoom has to move it and what that trades away.
        let datum: GroundDatum
    }

    private var samplerTemplate: SamplerTemplate?

    /// The stitched surface the chunk is drawn from, kept so a ground zoom can re-read the grids
    /// already in hand against a new mapping instead of fetching to change scale.
    private var terrainField: TerrainHeightField?

    private func setTerrainProjection(grids: [(x: Int, y: Int, grid: ElevationGrid)]) {
        guard let template = samplerTemplate, !grids.isEmpty else { return }
        let elevationScale = template.elevationScale
        let heightField = TerrainHeightField(
            grids: grids.map(\.grid),
            tilePositions: grids.map { (x: $0.x, y: $0.y) },
            anchor: template.anchor,
            elevationScale: elevationScale,
            baselineElevation: template.baselineElevation
        )
        projection = TerrainProjection(heightField: heightField, panOffset: panOffset)
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
            physicalSize: configuration.physicalSize,
            boundary: configuration.boundary,
            style: style,
            panRange: configuration.panRange
        )
        rootEntity.setTiles3D(tiles3DEntity)
        // Attribution surfaces through the store so the views can draw it: displaying the sources
        // credited by the tiles in view is a condition of the tile services' terms, not decoration.
        tiles3DEntity.onAttributionChange = { [weak self] text in
            self?.tilesAttribution = text
        }
        // The same two operations the entity itself applies — rotate into the local ENU frame about
        // the centre, then scale — so a coordinate lands in the frame the geometry arrived in.
        projection = EllipsoidProjection(
            center: configuration.center,
            radiusMeters: configuration.radiusMeters,
            physicalSize: configuration.physicalSize,
            datumElevation: tiles3DEntity.groundDatumElevation ?? 0
        )
    }

    /// Follows the photorealistic model's underside as refinement and panning move it.
    ///
    /// The datum is measured over what is on screen, so it settles rather than being known at load.
    /// Nothing else about the projection changes, which is why this re-stamps one field instead of
    /// rebuilding it.
    private func refreshPhotorealisticDatum() {
        guard var ellipsoid = projection as? EllipsoidProjection,
              let datum = (dioramaEntity as? DioramaEntity)?.tiles3D?.groundDatumElevation
        else { return }
        guard datum != ellipsoid.datumElevation else { return }
        ellipsoid.datumElevation = datum
        projection = ellipsoid
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

    /// The gesture's path, which a step reads a fixed distance behind rather than draining.
    private var panResampler = PanPathResampler()

    /// Whether a pan step is already on its way.
    private var isFlushingPan = false

    /// Lands the tail of a gesture once the touches stop arriving.
    private var panTailTask: Task<Void, Never>?

    /// How long after the last touch the tail lands. Longer than a frame, so an ordinary gesture
    /// cancels it and only a gesture that has actually stopped ever pays for it.
    private static let panTailDelay: Duration = .milliseconds(32)

    /// Slides the terrain beneath the chunk's outline by a delta.
    ///
    /// Applied once per turn of the main actor rather than immediately, because a pan step costs
    /// more than the interval a finger delivers touches at — 10–20 ms of resampling and effect work
    /// against an event every 8 ms on a 120 Hz display. Applied as they arrive, the steps queue
    /// behind each other and the ground goes on moving after the finger has stopped: a measured
    /// 640 ms drag produced 80 steps spanning 975 ms, so a third of the movement happened with
    /// nothing touching the screen. That reads as momentum nobody asked for, and it gets worse the
    /// faster the events arrive. Applying one step per turn makes the gesture's own work an
    /// addition, so the queue drains as fast as it fills.
    ///
    /// What that step *is* is ``PanPathResampler``'s question rather than a sum of the deltas since
    /// the last one: touches and frames run on clocks that are not in phase, so summing gives a
    /// frame that caught two touch samples two thirds the movement of one that caught three. The
    /// distance is right and the speed is not, which is what reads as judder. Resampling the path at
    /// the frame's own time gives every frame the movement its own duration earns.
    ///
    /// - Parameters:
    ///   - delta: Movement in diorama meters.
    ///   - timestamp: When the touches behind `delta` were sampled, in the clock the platform's
    ///     events carry. Defaults to `nil` for inputs that timestamp nothing.
    public func pan(by delta: SIMD2<Float>, at timestamp: TimeInterval? = nil) {
        panTailTask?.cancel()
        panTailTask = nil
        panResampler.add(delta, touchTime: timestamp, now: ProcessInfo.processInfo.systemUptime)

        guard !isFlushingPan else { return }
        isFlushingPan = true
        Task { [weak self] in
            guard let self else { return }
            isFlushingPan = false
            flushPan()
        }
    }

    /// Moves the ground as far as the gesture's path has reached by now, and arranges to come back
    /// for the rest.
    ///
    /// The rest is real: a step reads the path one touch interval behind, so the newest movement is
    /// always still in hand. Nothing else would ask for it once a gesture ends — the flush is driven
    /// by touches arriving — and the ground would settle a touch interval short of where the finger
    /// left it. The tail is one extra step, and only ever runs when the touches have stopped.
    private func flushPan() {
        let step = panResampler.step(now: ProcessInfo.processInfo.systemUptime)
        if step != .zero {
            setPanOffset(panOffset + step)
        }

        guard panResampler.hasUnappliedMovement else { return }
        panTailTask?.cancel()
        panTailTask = Task { [weak self] in
            try? await Task.sleep(for: Self.panTailDelay)
            guard let self, !Task.isCancelled else { return }
            panTailTask = nil
            flushPan()
        }
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

        let moved = simd_length(target - panOffset)
        panOffset = target
        projection?.panOffset = target

        // Split, because the three parts of a pan step are paid for differently: the resample is
        // fixed by the chunk's vertex count (or, on the photorealistic path, by how much of the rim
        // the outline moved across), an effect's cost rides on what it traces, and how far the step
        // moved is the gesture's own business rather than the chunk's — a steady drag whose steps
        // vary in length is judder even when every step is cheap. Logging one total would hide which
        // of them a slow pan is. Logged on every path, so the pan can be measured where it is
        // slowest rather than only where an effect happens to be attached.
        let started = ContinuousClock.now
        (dioramaEntity as? DioramaEntity)?.terrain?.setPanOffset(target)
        (dioramaEntity as? DioramaEntity)?.tiles3D?.setPanOffset(target)
        refreshPhotorealisticDatum()
        // Buildings are anchored to geography like the content below, but they are geometry rather
        // than placed entities, so they ride one transform instead of being repositioned. The
        // transform keeps them over their own ground; which of them the outline covers is a separate
        // question, answered off the main actor by `recutBuildingsIfNeeded` below.
        (dioramaEntity as? DioramaEntity)?.buildings?.setPanOffset(target)
        let resampled = ContinuousClock.now
        refreshEffect()
        let finished = ContinuousClock.now
        logger.debug("""
            Pan step: moved \(String(format: "%.3f", moved * 1000)) mm, resample \
            \(String(format: "%.1f", (resampled - started).milliseconds)) ms, \
            effect \(String(format: "%.1f", (finished - resampled).milliseconds)) ms
            """)

        // Content is anchored to geography, so it has to move with the ground.
        applyContent(appliedContent)

        recutBuildingsIfNeeded()
        refetchBuildingsIfNeeded()
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

    /// Which set of tile coordinates the chunk is currently speaking in.
    ///
    /// A ``TerrainTileSet`` is keyed by tile coordinate with no level in the key, so the same key
    /// names entirely different ground at a different zoom. A fetch takes hundreds of milliseconds
    /// and a re-level or a reload can land inside one, which would leave a roll applying level-11
    /// tiles as though they were level-10 tiles — ground from a hundred kilometres away, placed with
    /// complete confidence. Anything that changes what a tile coordinate *means* bumps this, and a
    /// fetch that comes back to a different number is thrown away rather than applied.
    ///
    /// A ground zoom pointedly does not bump it. It changes the map the resident tiles are read
    /// through, not which tiles they are, and a fetch in flight across one lands perfectly well —
    /// see ``applyRoll(_:)``, which places whatever arrives through the mapping in force when it
    /// arrives rather than the one it was requested under.
    private var tileGeneration = 0

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
            // Only a task that was not cancelled may clear the handle. `reset()` cancels this one
            // and nils the handle itself, so a cancelled roll finishing its await later would
            // otherwise clear the handle of the roll that replaced it — releasing the guard that
            // keeps exactly one in flight.
            defer { if !Task.isCancelled { rollTask = nil } }
            while let state = rolling, !Task.isCancelled {
                // The gate at the zoom step covers only *issuing* this task, and a roll outlives the
                // step that started it — so the loop has to ask again. A roll admitted at scale 1.3,
                // where the level in hand was still the level wanted, goes on re-issuing at that
                // level as the pinch runs to scale 12, and every window it brings is thrown away by
                // the re-level that follows. Each of those is a fetch and a discard for ground
                // nothing will read: measured on one full-width pinch, ungated gave four rolls and
                // two `Discarded a roll …` lines against two rolls and none with this in.
                guard let template = samplerTemplate,
                      desiredTileZoom(for: template, scale: groundScale) == template.zoom else { return }

                let required = state.roller.window(forPanOffset: panOffset)
                guard !state.window.contains(required) else { return }

                let issuedAt = tileGeneration
                guard let roll = await state.roller.load(window: required, have: state.tiles) else {
                    logger.warning("Terrain roll loaded nothing; staying on the ground already held")
                    return
                }
                guard !Task.isCancelled, rolling != nil else { return }

                // A re-level or a reload landed while this was in flight, so these tile coordinates
                // no longer name the ground the chunk is standing on. Start again against what the
                // chunk is actually reading now; the tiles themselves are in the cache either way.
                guard issuedAt == tileGeneration else {
                    logger.debug("Discarded a roll that landed at z\(state.roller.zoom) after a re-level")
                    continue
                }

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
    ///
    /// The grids are re-placed through the mapping in force *now* rather than kept where the roller
    /// put them. A fetch takes hundreds of milliseconds and a pinch does not stop for it, so the
    /// scale the roll was requested at is routinely not the scale it lands at — and a height field
    /// built against the old one would put the chunk back a step of zoom the moment the ground
    /// arrived, which reads as the map flinching mid-gesture. Placing at landing costs one height
    /// field rebuild over the same grids and is exactly what the roller would have produced had it
    /// been asked a moment later.
    @discardableResult
    private func applyRoll(_ roll: TerrainRoll) -> Bool {
        guard let template = samplerTemplate else { return false }

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

        let field = TerrainHeightField(
            grids: roll.heightField.grids,
            tilePositions: roll.heightField.tilePositions,
            anchor: template.anchor,
            elevationScale: template.elevationScale,
            baselineElevation: template.baselineElevation
        )

        mosaic = image
        terrainField = field
        (dioramaEntity as? DioramaEntity)?.terrain?.setTerrain(
            field,
            surfaceMaterial: material
        )
        // New ground means new heights, and the roll has just handed the chunk a fresh surface
        // material — which paints the imagery back over a chunk the effect had darkened.
        reapplyEffect()

        // The sampler reads the same ground, so it moves with it or markers drift off the terrain.
        setTerrainProjection(
            grids: field.tilePositions.enumerated().map { index, position in
                (x: position.x, y: position.y, grid: field.grids[index])
            }
        )
        applyContent(appliedContent)

        // The blocks stand on ground that has just been replaced, and a roll can move a sample by a
        // few metres where the stitched seam falls differently — so they are re-seated even though
        // the outline has not moved. The anchor survives a roll, so their footprints do not have to
        // be projected again.
        buildings?.heightField = field
        buildings?.blocksStale = true
        buildings?.generation += 1
        recutBuildingsIfNeeded()

        logger.debug(
            """
            Rolled terrain to tiles x \(roll.window.minX)...\(roll.window.maxX), \
            y \(roll.window.minY)...\(roll.window.maxY)
            """
        )
        return true
    }

    // MARK: - Ground Zoom

    /// How much more ground the chunk covers than its configuration asked for.
    ///
    /// 1 is the region ``DioramaConfiguration/radiusMeters`` names; 2 is twice that much world
    /// across the same chunk. This is the **map** zooming rather than the camera pulling back — the
    /// chunk keeps its size, its outline and its place on the table, and only the ground beneath it
    /// gets wider. Panning is unaffected and goes on working throughout, because a zoom and a pan
    /// change different halves of the same mapping.
    public private(set) var groundScale: Float = 1

    /// The real-world radius the chunk currently spans.
    public var groundRadiusMeters: Double { configuration.radiusMeters * Double(groundScale) }

    /// The range the ground zoom may run over.
    ///
    /// The far end is a flat chunk's honest limit rather than Mercator's. Mercator itself only runs
    /// out at tile level 0, where the whole planet is one tile — but a continent laid flat on a
    /// tabletop is a projection nobody wants to look at, and the elevation grid backing it would be
    /// a couple of hundred samples for a hemisphere. It stops at ``worldTileZoom`` instead, a few
    /// levels short, which is the point where the sphere is the better answer and the globe takes
    /// over.
    ///
    /// The near end stops a few steps in, because zooming in means magnifying the tiles already
    /// fetched: the chunk never asks for a level finer than the one it loaded at, so past a small
    /// factor it would be claiming detail that was never established to be there.
    public var groundScaleLimits: ClosedRange<Float> {
        guard let template = samplerTemplate, canZoomGround else { return 1...1 }
        let levels = max(template.baseAnchor.zoom - Self.worldTileZoom, 0)
        return Self.minimumGroundScale...max(exp2(Float(levels)), 1)
    }

    /// The tile level the chunk stops widening at, and the globe takes the gesture on from.
    ///
    /// Sixteen tiles across the world: a chunk at this level is spanning something like a thousand
    /// kilometres, which is the scale at which the flat cut stops reading as a piece of the earth.
    nonisolated static let worldTileZoom = 4

    /// Whether the ground can be zoomed at all.
    ///
    /// It rides on the same machinery panning does — a resampled surface and a rolling fetch — so a
    /// fixed chunk has neither the surface to re-read nor the tiles to widen onto.
    public var canZoomGround: Bool { rolling != nil && terrainField != nil }

    private static let minimumGroundScale: Float = 0.25

    /// Widens or narrows the ground the chunk covers, keeping the chunk itself exactly as it is.
    ///
    /// Cheap, and for the same reason a pan step is: which ground a diorama position names is the
    /// *anchor's* business, not the mosaic's, so multiplying the anchor's scale is the whole zoom.
    /// The surface re-reads the tiles already in hand — one resample, no fetch — and the imagery
    /// stretches across the chunk until coarser tiles arrive to replace it.
    ///
    /// Three things move together with the scale, and leaving any one of them out fails quietly:
    ///
    /// - **The pan offset divides by the same factor.** The ground under the chunk is
    ///   `originTile + panOffset · tilesPerDioramaMeter`, and scaling only the second term slides
    ///   the terrain sideways by however far it had been panned. Dividing the offset leaves the
    ///   product exactly unchanged, so a zoom is about the place the chunk is looking at rather than
    ///   about wherever it started.
    /// - **The elevation scale divides by it too.** Covering twice the ground across the same
    ///   physical width makes a metre of relief worth half as many diorama metres; hold it fixed and
    ///   the mountains grow as the map pulls back.
    /// - **The margin ring is re-counted.** A tile spans half as much diorama distance at twice the
    ///   scale, so the ring the roller keeps beyond the outline has to be measured in the new tiles
    ///   or the chunk pans off its own margin immediately.
    ///
    /// And one thing deliberately does *not* move: ``TerrainEntity/baseDepth``. The earth mass is
    /// what the strata wall is made of, so scaling it would answer a gesture about the *map* by
    /// resizing the object — the wall growing as the ground widens and shrinking on the way back in.
    ///
    /// The *fourth* thing that moves is what keeps the wall a fixed height rather than merely a
    /// fixed depth: the elevation baseline. What the eye reads off the silhouette is the strata band
    /// — `baseDepth + rimY` — and with the base pinned, `rimY` compressing with everything else on
    /// the map would take the band down with it. So the terrain is compressed about the rim rather
    /// than about its own floor, by handing the height field a datum derived from the scale. The
    /// rule and everything it trades away are in ``GroundDatum``; the
    /// short version is that Y = 0 is the lowest ground at the scale the chunk was generated at and
    /// the rim datum at every other.
    ///
    /// It is still not *measured* — same discipline as a roll, and for the same reason. A datum read
    /// off the tiles in hand moves when they change, and a datum that moves makes the chunk bob;
    /// this one is a pure function of the ground scale over values frozen at generation, so a pan
    /// cannot touch it and neither can a roll.
    ///
    /// - Parameter scale: The target scale, clamped to ``groundScaleLimits``.
    public func setGroundScale(_ scale: Float) {
        guard canZoomGround,
              let template = samplerTemplate,
              let field = terrainField
        else { return }

        let limits = groundScaleLimits
        let target = min(max(scale, limits.lowerBound), limits.upperBound)
        guard abs(target / groundScale - 1) > 1e-4 else { return }

        let started = ContinuousClock.now
        let offset = panOffset * (groundScale / target)
        guard let mapping = applyMapping(scale: target, zoom: template.zoom) else { return }

        // The grids in hand, read through the new mapping. Same tiles, same stitching — only the map
        // they are placed against has changed, and the datum is part of that map rather than a
        // measurement of them.
        let zoomed = TerrainHeightField(
            grids: field.grids,
            tilePositions: field.tilePositions,
            anchor: mapping.anchor,
            elevationScale: mapping.elevationScale,
            baselineElevation: mapping.baselineElevation
        )

        groundScale = target
        panOffset = offset
        terrainField = zoomed

        let entity = dioramaEntity as? DioramaEntity
        entity?.terrain?.setTerrain(
            zoomed,
            surfaceMaterial: nil,
            panOffset: offset,
            groundScale: target
        )
        // Sea level is an elevation like any other, so it rides the elevation scale down. Moving the
        // plane rather than rebuilding it is enough: it is cut to the outline, which has not moved —
        // and the height goes through the same rule the load path used, so the lift that keeps the
        // water off a flat seabed does not get left behind by a zoom.
        if let water = entity?.waterPlane {
            water.position.y = WaterPlaneEntity.surfaceY(
                boundary: configuration.boundary,
                baselineElevation: mapping.baselineElevation,
                elevationScale: mapping.elevationScale
            )
        }
        projection?.panOffset = offset
        refreshEffect()

        // The projection reads the same surface the chunk was just re-sampled from, so it is handed
        // `zoomed` rather than a field rebuilt from its parts. Going through
        // ``setTerrainProjection(grids:)`` here took the grids apart into tuples and put them back
        // together into a height field identical to this one — which is not merely redundant but
        // the more expensive half of the step, since constructing a field measures every resident
        // grid's extremes.
        projection = TerrainProjection(heightField: zoomed, panOffset: offset)
        applyContent(appliedContent)

        buildings?.heightField = zoomed
        buildings?.blocksStale = true
        buildings?.generation += 1
        recutBuildingsIfNeeded()

        let finished = ContinuousClock.now
        // The band is `earth mass + rim`, and the rim is the half a zoom used to take away — so it is
        // logged beside the depth rather than left to be inferred from a screenshot. `pinned` is what
        // the datum rule holds it at; `rim` is where it actually lands, and the two part company only
        // by however much the ground under the outline has changed as the map widened.
        let rim = GroundDatum.measured(boundary: configuration.boundary, heightField: zoomed).rim
        logger.debug("""
            Ground zoom: scale \(target, format: .fixed(precision: 3)), \
            radius \(self.groundRadiusMeters, format: .fixed(precision: 0)) m, \
            tiles at z\(template.zoom), \
            earth mass \(entity?.terrain?.baseDepth ?? 0, format: .fixed(precision: 4)) m, \
            rim \((rim - mapping.baselineElevation) * mapping.elevationScale, format: .fixed(precision: 4)) m \
            (pinned \(template.datum.rimHeight(generatedElevationScale: template.baseElevationScale), format: .fixed(precision: 4)) m), \
            \(String(format: "%.1f", (finished - started).milliseconds)) ms
            """)

        relevelTerrainIfNeeded()
        // **A roll at a level that is being replaced is pure waste.** The re-level fetches its own
        // whole window rather than carrying tiles over — it must, since a tile key means nothing
        // without its level — so anything a roll brought at the old level is discarded on arrival,
        // which is what the "discarded a roll" line above reports. On an ordinary pinch step that is
        // one wasted window; on the jump ``restoreGroundScale(_:)`` makes it is a fetch storm, since
        // the scale lands a couple of hundred out ahead of the tiles and the margin ring is counted
        // in tiles that now span almost none of the chunk. Measured on a globe return from the
        // ceiling: **1,608 z12 tiles requested and thrown away**, against the 20 the re-level
        // actually drew with.
        //
        // The re-level hands the roll back on both of its failure paths, so a level that cannot be
        // reached does not leave the chunk without its margin.
        if let template = samplerTemplate, desiredTileZoom(for: template, scale: target) == template.zoom {
            rollTerrainIfNeeded()
        }
    }

    /// Restates the map the chunk reads its resident grids through, at `scale` and tile level `zoom`.
    ///
    /// The two things that move the map land here — a ground zoom, which changes the scale and keeps
    /// the level, and a re-level, which changes the level and keeps the scale — so there is one
    /// place that knows an anchor, an elevation scale and a margin ring have to move together.
    /// Splitting them was how the re-level came to apply an anchor built before its own fetch: it
    /// restated the mapping from a scale that had been correct several hundred milliseconds and a
    /// good deal of pinch ago, and the ground jumped back to it as the tiles landed.
    ///
    /// Both terms are derived from `baseAnchor`/`baseElevationScale` rather than from what is in
    /// force, so a hundred steps of a pinch cannot accumulate drift the scale can no longer be read
    /// back from.
    ///
    /// It moves the map only. The height field, the entity and everything standing on the ground are
    /// the caller's to bring across, because a zoom re-reads the grids it already has while a
    /// re-level brings its own.
    @discardableResult
    private func applyMapping(
        scale: Float,
        zoom: Int
    ) -> (anchor: TerrainAnchor, elevationScale: Float, baselineElevation: Float)? {
        guard let template = samplerTemplate, let state = rolling else { return nil }

        let anchor = template.baseAnchor.atZoom(zoom).scaled(by: Double(scale))
        let elevationScale = template.baseElevationScale / scale
        let baseline = template.datum.baseline(atGroundScale: scale)

        samplerTemplate?.zoom = zoom
        samplerTemplate?.anchor = anchor
        samplerTemplate?.elevationScale = elevationScale
        samplerTemplate?.baselineElevation = baseline

        // A tile spans a different amount of chunk at every scale and level, so the ring the roller
        // keeps beyond the outline is re-counted in the tiles it is now made of.
        let perTile = anchor.dioramaMetersPerTile
        let margin = configuration.maximumPanOffset
        rolling = TerrainRollState(
            roller: state.roller.remapped(
                anchor: anchor,
                elevationScale: elevationScale,
                baselineElevation: baseline,
                marginTiles: SIMD2(
                    Self.marginTiles(meters: margin.x, perTile: perTile.x),
                    Self.marginTiles(meters: margin.y, perTile: perTile.y)
                )
            ),
            tiles: state.tiles,
            window: state.window
        )
        return (anchor, elevationScale, baseline)
    }

    /// Zooms the ground by a multiplier, which is what a pinch produces.
    public func zoomGround(by factor: Float) {
        guard factor > 0 else { return }
        setGroundScale(groundScale * factor)
    }

    // MARK: - Tile Re-levelling

    /// The tile level the ground zoom currently wants.
    ///
    /// Tile space doubles per level and so does the ground zoom, so one level answers one doubling
    /// and the mosaic is never stretched by more than about √2 either way. Rounding rather than
    /// flooring is what centres that: floor would let it reach 2× before correcting, which is
    /// visibly soft. It never goes *finer* than the level the chunk loaded at — that would be asking
    /// for detail the fetch never established was there — and stops at 0, where the world is one
    /// tile and there is nothing coarser to ask for.
    nonisolated static func desiredTileZoom(base: Int, scale: Float) -> Int {
        let steps = Int(log2(Double(scale)).rounded())
        let coarsest = min(worldTileZoom, base)
        return min(max(base - steps, coarsest), base)
    }

    private func desiredTileZoom(for template: SamplerTemplate, scale: Float) -> Int {
        Self.desiredTileZoom(base: template.baseAnchor.zoom, scale: scale)
    }

    private var relevelTask: Task<Void, Never>?

    /// How long the ground scale must hold still before a re-level commits to a tile level.
    ///
    /// Long enough that an ordinary pinch is over by the time it elapses, short enough to disappear
    /// against the window fetch that follows it — a fetch is several hundred milliseconds, so this
    /// costs a fraction of the one it saves.
    private static let relevelSettleInterval = Duration.milliseconds(120)

    /// Fetches the ground again at a coarser tile level once the mosaic has stretched far enough.
    ///
    /// The zoom itself needs no fetch, which is what makes it cheap — but it *stretches* what is in
    /// hand, and past a factor of two the imagery is visibly soft and the elevation grid carries
    /// fewer samples across the chunk than the mesh has vertices. Coarser tiles are the fix rather
    /// than more of the ones already held: a level out covers four times the ground per tile, so
    /// staying put would mean four times the tiles for the same view.
    ///
    /// It lands the way a roll does — built off the main actor, swapped in whole, no teardown and no
    /// spinner — because the anchor makes the two windows name identical ground.
    private func relevelTerrainIfNeeded() {
        guard relevelTask == nil, let template = samplerTemplate, rolling != nil else { return }
        guard desiredTileZoom(for: template, scale: groundScale) != template.zoom else { return }

        relevelTask = Task { [self] in
            // Same reasoning as the roll: only a task that was not cancelled may clear the handle,
            // or a cancelled re-level finishing later releases the guard on the one that replaced it.
            defer { if !Task.isCancelled { relevelTask = nil } }
            while !Task.isCancelled {
                // **Let the pinch finish before choosing a level.** This fires from the first zoom
                // step to cross the threshold, which is the *start* of a gesture whose end is
                // several rungs coarser — and a window fetch is far longer than the gesture, so the
                // level asked for is stale before it is even in flight. The guard below then
                // discards those tiles on landing, correctly, but the fetch has already been paid
                // for: measured on a full-width outward pinch, a z11 window was fetched and thrown
                // away before the z8 the chunk actually wanted could be asked for at all. One short
                // settle is a tenth of the wait it removes.
                while !Task.isCancelled {
                    let before = groundScale
                    try? await Task.sleep(for: Self.relevelSettleInterval)
                    guard !Task.isCancelled else { return }
                    if groundScale == before { break }
                }
                guard let template = samplerTemplate, let state = rolling, !Task.isCancelled else { return }
                let wanted = desiredTileZoom(for: template, scale: groundScale)
                guard wanted != template.zoom else { return }

                // Enough of a mapping to *ask* with. What the tiles are placed against is decided
                // below, once they have arrived — see the note there.
                let requested = template.baseAnchor.atZoom(wanted).scaled(by: Double(groundScale))
                let perTile = requested.dioramaMetersPerTile
                let margin = configuration.maximumPanOffset
                let roller = state.roller.remapped(
                    anchor: requested,
                    elevationScale: template.elevationScale,
                    baselineElevation: template.baselineElevation,
                    marginTiles: SIMD2(
                        Self.marginTiles(meters: margin.x, perTile: perTile.x),
                        Self.marginTiles(meters: margin.y, perTile: perTile.y)
                    )
                )

                // Nothing carries over: a `TerrainTileSet` is keyed by tile coordinate with no level
                // in the key, so handing over the old tiles would have the new window read them as
                // its own and place ground from somewhere else entirely.
                let issuedAt = tileGeneration
                guard let roll = await roller.load(
                    window: roller.window(forPanOffset: panOffset),
                    have: TerrainTileSet()
                ) else {
                    logger.warning("Tile re-level loaded nothing; staying at z\(template.zoom)")
                    // The zoom step declined to roll on the strength of this re-level, so the margin
                    // ring is this one's to restore before it gives up.
                    rollTerrainIfNeeded()
                    return
                }
                guard !Task.isCancelled, rolling != nil else { return }

                // Something else changed what a tile coordinate names while this was in flight — a
                // reload, or a re-level that beat this one home. These tiles are level-`wanted`
                // tiles and the chunk is no longer reading at that level, so go round again against
                // what it is actually reading now.
                guard issuedAt == tileGeneration else { continue }

                // And the *level* is re-decided against the scale in force now, for the same reason
                // the mapping below is. A pinch runs to its end in a couple of hundred milliseconds
                // and a window fetch takes longer than that, so the level that was wanted when this
                // was issued is routinely several rungs finer than the one wanted when it lands —
                // and applying it anyway buys a mosaic that is still stretched, at the cost of a
                // whole height-field rebuild, a re-composite, a resample, and a `tileGeneration`
                // bump that throws away whatever roll was in flight. Going round instead fetches the
                // level actually wanted, so the ladder is walked in one landing rather than one
                // landing per rung. Measured on a full-width outward pinch: three applied re-levels
                // (z11 mid-gesture, then z10, then z8) with the chunk re-texturing for 0.958 s after
                // the fingers lifted became one (z8) landing 0.230 s after them.
                guard desiredTileZoom(for: template, scale: groundScale) == wanted else { continue }

                // The mapping is restated at the scale in force *now*, not the one the fetch was
                // issued under. A fetch is hundreds of milliseconds and a pinch does not stop for
                // it, so `requested` is routinely a scale or more out of date by the time the tiles
                // land — and applying it would haul the ground back to where the pinch had got to
                // when it started, which reads as the map flinching as it sharpens.
                let previousZoom = template.zoom
                guard applyMapping(scale: groundScale, zoom: wanted) != nil else { return }
                guard applyRoll(roll) else {
                    applyMapping(scale: groundScale, zoom: previousZoom)
                    rollTerrainIfNeeded()
                    return
                }
                rolling?.tiles = roll.tiles
                rolling?.window = roll.window
                tileGeneration += 1
                logger.debug("Re-levelled terrain to z\(wanted) at ground scale \(self.groundScale)")
            }
        }
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
            projection: projection
        )

        rootEntity.applyContent(
            content,
            using: proxy,
            physicalSize: configuration.physicalSize
        )
        routePreviewEntity = rootEntity.routePreview
    }
}
