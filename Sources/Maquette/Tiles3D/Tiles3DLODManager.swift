import Foundation
import RealityKit
import os

/// Manages level-of-detail loading for OGC 3D Tiles.
///
/// Traverses the tile tree, loading high-detail tiles near the camera
/// and unloading distant tiles to manage memory.
@Observable
@MainActor
public final class Tiles3DLODManager {
    private let provider: any Tiles3DProvider
    private let ecefConverter: ECEFConverter
    private let radiusMeters: Double
    private let logger = Logger(subsystem: "com.maquette", category: "Tiles3DLODManager")

    private var rootTileset: TilesetJSON?
    private var loadedEntities: [String: Entity] = [:]
    private var tileLoader: Tile3DLoader?
    private var framesSinceVisible: [String: Int] = [:]

    /// Maximum simultaneous tile loads.
    public var maxConcurrentLoads: Int = 4

    /// Screen-space error threshold (pixels). Lower = more detail.
    public var screenSpaceErrorThreshold: Double = 16.0

    /// Number of frames before an unseen tile is evicted.
    public var evictionFrameThreshold: Int = 60

    init(provider: any Tiles3DProvider, ecefConverter: ECEFConverter, radiusMeters: Double) {
        self.provider = provider
        self.ecefConverter = ecefConverter
        self.radiusMeters = radiusMeters
    }

    /// Loads the root tileset and prepares for tile management.
    func start() async throws {
        let tileset = try await provider.fetchTileset()
        self.rootTileset = tileset
        self.tileLoader = Tile3DLoader(provider: provider, ecefConverter: ecefConverter)
        logger.info("Loaded root tileset (version: \(tileset.asset.version), geometricError: \(tileset.geometricError))")
    }

    /// Updates visible tiles based on camera position.
    func update(
        parentEntity: Entity,
        cameraPosition: SIMD3<Float>,
        screenHeight: Float,
        fov: Float
    ) async {
        guard let rootTileset, let tileLoader else { return }

        var visibleURIs = Set<String>()

        await traverseTile(
            rootTileset.root,
            parentTransform: .init(diagonal: .one),
            parentEntity: parentEntity,
            cameraPosition: cameraPosition,
            screenHeight: screenHeight,
            fov: fov,
            loader: tileLoader,
            visibleURIs: &visibleURIs
        )

        // Evict tiles not visible
        for (uri, entity) in loadedEntities {
            if !visibleURIs.contains(uri) {
                let count = (framesSinceVisible[uri] ?? 0) + 1
                framesSinceVisible[uri] = count
                if count > evictionFrameThreshold {
                    entity.removeFromParent()
                    loadedEntities.removeValue(forKey: uri)
                    framesSinceVisible.removeValue(forKey: uri)
                    logger.debug("Evicted tile: \(uri)")
                }
            } else {
                framesSinceVisible[uri] = 0
            }
        }
    }

    // MARK: - Tile Tree Traversal

    private func traverseTile(
        _ tile: TileJSON,
        parentTransform: simd_float4x4,
        parentEntity: Entity,
        cameraPosition: SIMD3<Float>,
        screenHeight: Float,
        fov: Float,
        loader: Tile3DLoader,
        visibleURIs: inout Set<String>
    ) async {
        let tileTransform: simd_float4x4
        if let transformArray = tile.transform, transformArray.count == 16 {
            tileTransform = parentTransform * simd_float4x4(columnMajorArray: transformArray)
        } else {
            tileTransform = parentTransform
        }

        // Compute screen-space error
        let bv = BoundingVolume(from: tile.boundingVolume, transform: tileTransform, ecefConverter: ecefConverter)
        let sse = bv?.screenSpaceError(
            geometricError: tile.geometricError,
            cameraPosition: cameraPosition,
            screenHeight: screenHeight,
            fov: fov
        ) ?? tile.geometricError

        let shouldRefine = sse > screenSpaceErrorThreshold && tile.children != nil

        if shouldRefine, let children = tile.children {
            // Refinement strategy
            let refine = tile.refine ?? .replace

            if refine == .add, let uri = tile.content?.uri {
                // ADD: render parent AND children
                await loadTileContent(uri: uri, transform: tileTransform, parentEntity: parentEntity, loader: loader)
                visibleURIs.insert(uri)
            }

            for child in children {
                await traverseTile(
                    child,
                    parentTransform: tileTransform,
                    parentEntity: parentEntity,
                    cameraPosition: cameraPosition,
                    screenHeight: screenHeight,
                    fov: fov,
                    loader: loader,
                    visibleURIs: &visibleURIs
                )
            }
        } else if let uri = tile.content?.uri {
            // Leaf or SSE below threshold — render this tile
            await loadTileContent(uri: uri, transform: tileTransform, parentEntity: parentEntity, loader: loader)
            visibleURIs.insert(uri)
        }
    }

    private func loadTileContent(
        uri: String,
        transform: simd_float4x4,
        parentEntity: Entity,
        loader: Tile3DLoader
    ) async {
        // Already loaded
        if loadedEntities[uri] != nil { return }

        // Limit concurrent loads
        guard loadedEntities.count < maxConcurrentLoads * 10 else { return }

        do {
            if let entity = try await loader.loadTile(uri: uri, transform: transform) {
                parentEntity.addChild(entity)
                loadedEntities[uri] = entity
                logger.debug("Loaded tile: \(uri)")
            }
        } catch {
            logger.warning("Failed to load tile \(uri): \(error)")
        }
    }
}

// MARK: - simd_float4x4 Extension

extension simd_float4x4 {
    /// Creates a matrix from a 16-element column-major array.
    init(columnMajorArray a: [Double]) {
        self.init(
            SIMD4<Float>(Float(a[0]), Float(a[1]), Float(a[2]), Float(a[3])),
            SIMD4<Float>(Float(a[4]), Float(a[5]), Float(a[6]), Float(a[7])),
            SIMD4<Float>(Float(a[8]), Float(a[9]), Float(a[10]), Float(a[11])),
            SIMD4<Float>(Float(a[12]), Float(a[13]), Float(a[14]), Float(a[15]))
        )
    }
}
