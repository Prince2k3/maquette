import CoreLocation
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
    private let center: CLLocationCoordinate2D
    private let radiusMeters: Double
    /// Outline to cut tile geometry to as it loads, or `nil` to leave tiles whole.
    private let clipPrism: BoundaryPrism?
    private let logger = Logger(subsystem: "com.maquette", category: "Tiles3DLODManager")

    private var rootTileset: TilesetJSON?
    private var loadedEntities: [String: Entity] = [:]
    private var tileLoader: Tile3DLoader?
    private var framesSinceVisible: [String: Int] = [:]
    private var subTilesets: [String: TilesetJSON] = [:]
    private var hasLoggedFirstTraversal = false

    /// Maximum simultaneous tile loads.
    public var maxConcurrentLoads: Int = 4

    /// Screen-space error threshold (pixels). Lower = more detail.
    public var screenSpaceErrorThreshold: Double = 16.0

    /// Number of frames before an unseen tile is evicted.
    public var evictionFrameThreshold: Int = 60

    init(
        provider: any Tiles3DProvider,
        ecefConverter: ECEFConverter,
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        clipPrism: BoundaryPrism? = nil
    ) {
        self.provider = provider
        self.ecefConverter = ecefConverter
        self.center = center
        self.radiusMeters = radiusMeters
        self.clipPrism = clipPrism
    }

    /// Loads the root tileset and prepares for tile management.
    func start() async throws {
        let tileset = try await provider.fetchTileset()
        self.rootTileset = tileset
        self.tileLoader = Tile3DLoader(provider: provider, ecefConverter: ecefConverter, clipPrism: clipPrism)
        logger.info("Loaded root tileset (version: \(tileset.asset.version), geometricError: \(tileset.geometricError))")

        // Log root tile structure for diagnostics
        let root = tileset.root
        let childCount = root.children?.count ?? 0
        let hasContent = root.content != nil
        let bvType: String
        if root.boundingVolume.region != nil { bvType = "region" }
        else if root.boundingVolume.box != nil { bvType = "box" }
        else if root.boundingVolume.sphere != nil { bvType = "sphere" }
        else { bvType = "none" }
        logger.info("Root tile: bvType=\(bvType) geometricError=\(root.geometricError) children=\(childCount) hasContent=\(hasContent) hasTransform=\(root.transform != nil)")
        if let children = root.children {
            for (i, child) in children.prefix(5).enumerated() {
                let cbv: String
                if child.boundingVolume.region != nil { cbv = "region" }
                else if child.boundingVolume.box != nil { cbv = "box" }
                else if child.boundingVolume.sphere != nil { cbv = "sphere" }
                else { cbv = "none" }
                logger.info("  child[\(i)]: bv=\(cbv) geoErr=\(child.geometricError) children=\(child.children?.count ?? 0) content=\(child.content?.uri ?? "nil")")
            }
            if children.count > 5 { logger.info("  ... and \(children.count - 5) more children") }
        }
    }

    /// Traversal statistics for diagnostics.
    private struct TraversalStats {
        var visited = 0
        var culled = 0
        var refined = 0
        var rendered = 0
        var noContent = 0
        var loadFailed = 0
        var draco = 0
        var subTilesetsLoaded = 0
        var maxDepth = 0
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
        var stats = TraversalStats()

        await traverseTile(
            rootTileset.root,
            parentTransform: simd_double4x4(diagonal: .one),
            parentEntity: parentEntity,
            cameraPosition: cameraPosition,
            screenHeight: screenHeight,
            fov: fov,
            loader: tileLoader,
            visibleURIs: &visibleURIs,
            stats: &stats,
            depth: 0
        )

        // Log first traversal and periodically after
        if !hasLoggedFirstTraversal || stats.rendered > 0 {
            logger.debug("LOD: visited=\(stats.visited) culled=\(stats.culled) refined=\(stats.refined) rendered=\(stats.rendered) noContent=\(stats.noContent) failed=\(stats.loadFailed) draco=\(stats.draco) subtilesets=\(stats.subTilesetsLoaded) depth=\(stats.maxDepth) loaded=\(self.loadedEntities.count)")
            hasLoggedFirstTraversal = true
        }

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
        parentTransform: simd_double4x4,
        parentEntity: Entity,
        cameraPosition: SIMD3<Float>,
        screenHeight: Float,
        fov: Float,
        loader: Tile3DLoader,
        visibleURIs: inout Set<String>,
        stats: inout TraversalStats,
        depth: Int
    ) async {
        stats.visited += 1
        stats.maxDepth = max(stats.maxDepth, depth)

        // Accumulate transforms in Double precision to preserve ECEF accuracy
        let tileTransform: simd_double4x4
        if let transformArray = tile.transform, transformArray.count == 16 {
            tileTransform = parentTransform * simd_double4x4(columnMajorArray: transformArray)
        } else {
            tileTransform = parentTransform
        }

        // Compute bounding volume in local coordinates
        let bv = BoundingVolume(from: tile.boundingVolume, transform: tileTransform, ecefConverter: ecefConverter)

        // Geographic culling: skip tiles entirely outside the diorama footprint
        if let bv, !bv.intersects(center: center, radiusMeters: radiusMeters) {
            stats.culled += 1
            return
        }

        // Compute screen-space error
        let sse = bv?.screenSpaceError(
            geometricError: tile.geometricError,
            cameraPosition: cameraPosition,
            screenHeight: screenHeight,
            fov: fov
        ) ?? tile.geometricError

        let shouldRefine = sse > screenSpaceErrorThreshold && tile.children != nil

        if shouldRefine, let children = tile.children {
            stats.refined += 1
            // Refinement strategy
            let refine = tile.refine ?? .replace

            if refine == .add, let uri = tile.content?.uri {
                // ADD: render parent AND children
                await handleContent(
                    uri: uri, transform: tileTransform, parentEntity: parentEntity,
                    cameraPosition: cameraPosition, screenHeight: screenHeight, fov: fov,
                    loader: loader, visibleURIs: &visibleURIs, stats: &stats, depth: depth
                )
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
                    visibleURIs: &visibleURIs,
                    stats: &stats,
                    depth: depth + 1
                )
            }
        } else if let uri = tile.content?.uri {
            // Leaf or SSE below threshold — render this tile
            stats.rendered += 1
            await handleContent(
                uri: uri, transform: tileTransform, parentEntity: parentEntity,
                cameraPosition: cameraPosition, screenHeight: screenHeight, fov: fov,
                loader: loader, visibleURIs: &visibleURIs, stats: &stats, depth: depth
            )
        } else {
            stats.noContent += 1
        }
    }

    // MARK: - Content Resolution (Sub-Tileset vs Geometry)

    /// Handles tile content which may be either a sub-tileset (JSON) or geometry (GLB/b3dm).
    ///
    /// Per the 3D Tiles spec, a tile's content can reference another tileset.json
    /// ("external tileset"). This method detects JSON responses, parses them as
    /// sub-tilesets, and recursively traverses their tile trees.
    private func handleContent(
        uri: String,
        transform: simd_double4x4,
        parentEntity: Entity,
        cameraPosition: SIMD3<Float>,
        screenHeight: Float,
        fov: Float,
        loader: Tile3DLoader,
        visibleURIs: inout Set<String>,
        stats: inout TraversalStats,
        depth: Int
    ) async {
        // Already loaded as geometry
        if loadedEntities[uri] != nil {
            visibleURIs.insert(uri)
            return
        }

        // Already resolved as sub-tileset — traverse it
        if let subTileset = subTilesets[uri] {
            await traverseTile(
                subTileset.root,
                parentTransform: transform,
                parentEntity: parentEntity,
                cameraPosition: cameraPosition,
                screenHeight: screenHeight,
                fov: fov,
                loader: loader,
                visibleURIs: &visibleURIs,
                stats: &stats,
                depth: depth + 1
            )
            return
        }

        // Limit concurrent loads
        guard loadedEntities.count < maxConcurrentLoads * 10 else { return }

        do {
            let data = try await provider.fetchTileContent(uri: uri)

            if Self.isJSONData(data) {
                // Sub-tileset: parse and traverse
                let subTileset = try JSONDecoder().decode(TilesetJSON.self, from: data)
                subTilesets[uri] = subTileset
                stats.subTilesetsLoaded += 1
                logger.info("Loaded sub-tileset: \(uri) (root children=\(subTileset.root.children?.count ?? 0))")
                await traverseTile(
                    subTileset.root,
                    parentTransform: transform,
                    parentEntity: parentEntity,
                    cameraPosition: cameraPosition,
                    screenHeight: screenHeight,
                    fov: fov,
                    loader: loader,
                    visibleURIs: &visibleURIs,
                    stats: &stats,
                    depth: depth + 1
                )
            } else {
                // Geometry: parse as GLB/b3dm
                if let entity = try await loader.loadTileFromData(data, uri: uri, transform: transform) {
                    parentEntity.addChild(entity)
                    loadedEntities[uri] = entity
                    visibleURIs.insert(uri)
                    logger.debug("Loaded tile: \(uri)")
                } else {
                    stats.draco += 1
                    logger.info("Skipped tile (unsupported format): \(uri)")
                }
            }
        } catch {
            stats.loadFailed += 1
            logger.warning("Failed to load tile \(uri): \(error)")
        }
    }

    /// Detects whether raw data is JSON (sub-tileset) vs binary (GLB/b3dm).
    ///
    /// Checks the first non-whitespace byte for `{` (0x7B) which indicates JSON.
    /// GLB starts with magic `0x46546C67` ("glTF") and b3dm with `0x6D643362`.
    private static func isJSONData(_ data: Data) -> Bool {
        // Find first non-whitespace byte
        for byte in data {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: // space, tab, newline, carriage return
                continue
            case 0x7B: // '{'
                return true
            default:
                return false
            }
        }
        return false
    }
}

// MARK: - simd_double4x4 Extension

extension simd_double4x4 {
    /// Creates a matrix from a 16-element column-major array (Double precision).
    init(columnMajorArray a: [Double]) {
        self.init(
            SIMD4<Double>(a[0], a[1], a[2], a[3]),
            SIMD4<Double>(a[4], a[5], a[6], a[7]),
            SIMD4<Double>(a[8], a[9], a[10], a[11]),
            SIMD4<Double>(a[12], a[13], a[14], a[15])
        )
    }
}
