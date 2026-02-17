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

/// View model responsible for orchestrating tile fetching, mesh generation, and entity assembly.
@Observable
@MainActor
public final class DioramaViewModel {
    /// Current loading state.
    public private(set) var loadingState: DioramaLoadingState = .idle

    /// The root diorama entity, available once loading completes.
    public private(set) var dioramaEntity: Entity?

    /// The active configuration.
    public var configuration: DioramaConfiguration

    private let tileCache = TileCache()
    private let logger = Logger(subsystem: "com.maquette", category: "DioramaViewModel")

    /// Creates a view model with the given configuration.
    public init(configuration: DioramaConfiguration) {
        self.configuration = configuration
    }

    /// Starts the async loading pipeline: fetch tiles, generate meshes, assemble entity tree.
    public func load() async {
        guard case .idle = loadingState else { return }
        loadingState = .loading

        do {
            let rootEntity = DioramaEntity()

            // Branch based on imagery source
            switch configuration.imagerySource {
            case .photorealistic(let provider):
                try await loadPhotorealisticPipeline(provider: provider, into: rootEntity)

            case .esriSatellite, .mapTilerSatellite:
                try await loadTerrainPipeline(into: rootEntity)
            }

            // Generate mask/pedestal (applies to all rendering paths)
            if let maskEntity = try? DioramaMask.generateMaskEntity(
                shape: configuration.shape,
                physicalDiameter: configuration.physicalDiameter,
                baseColor: configuration.baseColor
            ) {
                rootEntity.setMask(maskEntity)
            }

            dioramaEntity = rootEntity
            loadingState = .loaded
            logger.info("Diorama loaded successfully")

        } catch let error as DioramaError {
            loadingState = .failed(error)
            logger.error("Diorama loading failed: \(error)")
        } catch {
            loadingState = .failed(.networkFailure(underlying: error))
            logger.error("Diorama loading failed: \(error)")
        }
    }

    /// Resets the view model to its initial state, discarding the loaded entity.
    public func reset() {
        loadingState = .idle
        dioramaEntity = nil
    }

    // MARK: - Terrain Mesh Pipeline

    /// Loads terrain + satellite imagery and assembles the terrain entity.
    private func loadTerrainPipeline(into rootEntity: DioramaEntity) async throws {
        let center = Coordinate(configuration.center)
        let zoom = configuration.zoomLevel ?? TileMath.optimalZoomLevel(
            radiusMeters: configuration.radiusMeters,
            latitude: center.latitude
        )

        let tiles = TileMath.tilesInRegion(
            center: center,
            radiusMeters: configuration.radiusMeters,
            zoom: zoom
        )

        logger.debug("Loading \(tiles.count) tiles at zoom \(zoom)")

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
        case .photorealistic:
            fatalError("Photorealistic imagery should use loadPhotorealisticPipeline")
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

        // Generate terrain mesh
        let terrainMesh = try TerrainMeshGenerator.generateMesh(
            from: terrainGrids.map(\.grid),
            tilePositions: terrainGrids.map { (x: $0.x, y: $0.y) },
            exaggeration: configuration.elevation == .realistic ? configuration.elevationExaggeration : 0,
            physicalDiameter: configuration.physicalDiameter,
            radiusMeters: configuration.radiusMeters
        )

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

        let terrainEntity = TerrainEntity(mesh: terrainMesh, material: terrainMaterial)
        rootEntity.setTerrain(terrainEntity)
    }

    // MARK: - Photorealistic 3D Tiles Pipeline

    /// Loads OGC 3D Tiles content (Google Photorealistic, Cesium ion).
    private func loadPhotorealisticPipeline(provider: any Tiles3DProvider, into rootEntity: DioramaEntity) async throws {
        let tiles3DEntity = try await Tiles3DEntity(
            provider: provider,
            center: configuration.center,
            radiusMeters: configuration.radiusMeters
        )
        rootEntity.setTiles3D(tiles3DEntity)
    }
}
