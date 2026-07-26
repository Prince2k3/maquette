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
        loadingState = .idle
        dioramaEntity = nil
        elevationSampler = nil
        routePreviewEntity = nil
        panOffset = .zero
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

        // The imagery mosaic spans the full tile grid, so the height field does too. The chunk
        // boundary is then cut out of that region — smaller than the region when panning is on,
        // and the leftover margin is what the terrain slides through.
        let heightField = TerrainHeightField(
            grids: terrainGrids.map(\.grid),
            tilePositions: terrainGrids.map { (x: $0.x, y: $0.y) },
            extent: configuration.terrainRegionExtent,
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
        elevationSampler = ElevationSampler(
            grids: terrainGrids.map(\.grid),
            tilePositions: terrainGrids.map { (x: $0.x, y: $0.y) },
            zoom: zoom,
            center: configuration.center,
            radiusMeters: configuration.terrainFetchRadiusMeters,
            physicalDiameter: configuration.terrainRegionExtent.x,
            exaggeration: exaggeration,
            globalMinElev: globalMinElev
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

    /// The furthest the terrain can slide before the chunk would overhang the fetched region.
    public var maximumPanOffset: SIMD2<Float> {
        configuration.maximumPanOffset
    }

    /// Slides the terrain beneath the chunk's outline by a delta, clamped to the fetched region.
    ///
    /// - Parameter delta: Movement in diorama meters.
    public func pan(by delta: SIMD2<Float>) {
        setPanOffset(panOffset + delta)
    }

    /// Slides the terrain to an absolute offset, clamped to the fetched region.
    ///
    /// The chunk keeps its shape and position; only the ground beneath it moves. Markers and
    /// polylines are repositioned so they stay attached to the terrain they sit on.
    ///
    /// - Parameter offset: The target offset in diorama meters.
    public func setPanOffset(_ offset: SIMD2<Float>) {
        guard configuration.panRange > 0 else { return }

        let limit = configuration.maximumPanOffset
        let clamped = simd_clamp(offset, -limit, limit)
        guard clamped != panOffset else { return }

        panOffset = clamped
        elevationSampler?.panOffset = clamped
        (dioramaEntity as? DioramaEntity)?.terrain?.setPanOffset(clamped)
        (dioramaEntity as? DioramaEntity)?.tiles3D?.setPanOffset(clamped)

        // Content is anchored to geography, so it has to move with the ground.
        applyContent(appliedContent)
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
