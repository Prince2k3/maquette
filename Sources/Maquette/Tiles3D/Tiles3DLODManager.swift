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
    /// Content already fetched that yielded nothing drawable — an unsupported format, or geometry
    /// entirely outside the boundary. Remembered so it is not re-fetched on every traversal.
    private var barrenTiles: Set<String> = []
    /// Content fetches currently in flight, so a tile is not requested twice.
    private var inFlight: Set<String> = []

    /// Maximum simultaneous tile loads.
    public var maxConcurrentLoads: Int = 4

    /// Screen-space error threshold (pixels). Lower = more detail.
    public var screenSpaceErrorThreshold: Double = 16.0

    /// Number of traversals an unseen tile survives before it becomes eligible for eviction.
    public var evictionFrameThreshold: Int = 60

    /// Traversal passes a single update may run before yielding.
    ///
    /// Bounded so a deep tileset cannot spin indefinitely; whatever is left is picked up by the
    /// next update.
    public var maxPassesPerUpdate: Int = 12

    /// Tiles retained before unseen ones start being evicted.
    ///
    /// This is a memory budget, not a limit on how much may be drawn. An earlier cap of
    /// `maxConcurrentLoads * 10` silently stopped loading anything once forty tiles existed.
    public var maxRetainedTiles: Int = 600

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
        var maxDepth = 0
    }

    /// Content the traversal wants but does not yet have.
    private struct ContentRequest {
        let uri: String
        let transform: simd_double4x4
    }

    /// Updates visible tiles based on camera position.
    ///
    /// Traversal only reads what is already known — it never waits on the network. Anything
    /// missing is recorded as a request and fetched afterwards, concurrently. Fetching inline
    /// made a single pass take as long as every tile it touched, so the view spent essentially
    /// all its time part-loaded.
    func update(
        parentEntity: Entity,
        cameraPosition: SIMD3<Float>,
        screenHeight: Float,
        fov: Float
    ) async {
        guard rootTileset != nil else { return }

        // Each pass can only descend as far as what is already resolved: a sub-tileset has to be
        // fetched before its children are even visible to the traversal. So a pass reaches one
        // level deeper than the last, and the update drives itself until coverage stops improving
        // rather than waiting for the view to ask again.
        for _ in 0..<maxPassesPerUpdate {
            let requests = selectVisibleTiles(
                cameraPosition: cameraPosition,
                screenHeight: screenHeight,
                fov: fov
            )
            if requests.isEmpty { return }

            let loadedBefore = loadedEntities.count
            let resolvedBefore = subTilesets.count + barrenTiles.count
            await fetch(requests, into: parentEntity)

            // Nothing arrived, so another pass would ask for exactly the same things.
            if loadedEntities.count == loadedBefore,
               subTilesets.count + barrenTiles.count == resolvedBefore {
                break
            }
        }

        // Tiles are added hidden and only shown once a traversal picks them, so whatever the last
        // fetch brought in needs one more selection. Without it the newest geometry stays
        // invisible until something else happens to trigger an update — which looks like the view
        // filling in while the camera moves and emptying again when it stops.
        _ = selectVisibleTiles(
            cameraPosition: cameraPosition,
            screenHeight: screenHeight,
            fov: fov
        )
    }

    /// Runs one traversal, shows what it selected, and returns the content it still needs.
    private func selectVisibleTiles(
        cameraPosition: SIMD3<Float>,
        screenHeight: Float,
        fov: Float
    ) -> [ContentRequest] {
        guard let rootTileset else { return [] }

        var visibleURIs = Set<String>()
        var requests: [ContentRequest] = []
        var stats = TraversalStats()

        _ = traverseTile(
            rootTileset.root,
            parentTransform: simd_double4x4(diagonal: .one),
            cameraPosition: cameraPosition,
            screenHeight: screenHeight,
            fov: fov,
            visibleURIs: &visibleURIs,
            requests: &requests,
            stats: &stats,
            depth: 0
        )

        applyVisibility(visibleURIs)
        evict(keeping: visibleURIs)

        if !hasLoggedFirstTraversal || requests.isEmpty {
            logger.debug("LOD: visited=\(stats.visited) culled=\(stats.culled) refined=\(stats.refined) rendered=\(stats.rendered) requested=\(requests.count) noContent=\(stats.noContent) barren=\(self.barrenTiles.count) subtilesets=\(self.subTilesets.count) depth=\(stats.maxDepth) loaded=\(self.loadedEntities.count)")
            hasLoggedFirstTraversal = true
        }

        return requests
    }

    // MARK: - Tile Tree Traversal

    /// Walks the tile tree, marking what should be visible and collecting what still needs loading.
    ///
    /// - Returns: `true` when this subtree can draw everything it covers. `false` means content is
    ///   still missing, which lets an ancestor stand in for it rather than leaving a hole.
    private func traverseTile(
        _ tile: TileJSON,
        parentTransform: simd_double4x4,
        cameraPosition: SIMD3<Float>,
        screenHeight: Float,
        fov: Float,
        visibleURIs: inout Set<String>,
        requests: inout [ContentRequest],
        stats: inout TraversalStats,
        depth: Int
    ) -> Bool {
        stats.visited += 1
        stats.maxDepth = max(stats.maxDepth, depth)

        // Accumulate transforms in Double precision to preserve ECEF accuracy
        let tileTransform: simd_double4x4
        if let transformArray = tile.transform, transformArray.count == 16 {
            tileTransform = parentTransform * simd_double4x4(columnMajorArray: transformArray)
        } else {
            tileTransform = parentTransform
        }

        let bv = BoundingVolume(from: tile.boundingVolume, transform: tileTransform, ecefConverter: ecefConverter)

        // Outside the diorama footprint entirely — nothing to draw, and no hole either.
        if let bv, !bv.intersects(center: center, radiusMeters: radiusMeters) {
            stats.culled += 1
            return true
        }

        let sse = bv?.screenSpaceError(
            geometricError: tile.geometricError,
            cameraPosition: cameraPosition,
            screenHeight: screenHeight,
            fov: fov
        ) ?? tile.geometricError

        if sse > screenSpaceErrorThreshold, let children = tile.children {
            stats.refined += 1

            var childrenCovered = true
            for child in children {
                // Every child is visited even once coverage is known to be incomplete, because
                // short-circuiting would leave their content unrequested and never loading.
                let covered = traverseTile(
                    child,
                    parentTransform: tileTransform,
                    cameraPosition: cameraPosition,
                    screenHeight: screenHeight,
                    fov: fov,
                    visibleURIs: &visibleURIs,
                    requests: &requests,
                    stats: &stats,
                    depth: depth + 1
                )
                childrenCovered = covered && childrenCovered
            }

            // ADD refinement always draws the parent alongside its children. REPLACE normally
            // hands over to them, but while they are still loading the parent stands in —
            // handing over first is what punches holes in a tileset that streams.
            let refine = tile.refine ?? .replace
            var parentDrawn = false
            if refine == .add || !childrenCovered, let uri = tile.content?.uri {
                parentDrawn = present(
                    uri: uri,
                    transform: tileTransform,
                    cameraPosition: cameraPosition,
                    screenHeight: screenHeight,
                    fov: fov,
                    visibleURIs: &visibleURIs,
                    requests: &requests,
                    stats: &stats,
                    depth: depth
                )
            }

            return childrenCovered || parentDrawn
        }

        guard let uri = tile.content?.uri else {
            stats.noContent += 1
            return true
        }

        return present(
            uri: uri,
            transform: tileTransform,
            cameraPosition: cameraPosition,
            screenHeight: screenHeight,
            fov: fov,
            visibleURIs: &visibleURIs,
            requests: &requests,
            stats: &stats,
            depth: depth
        )
    }

    /// Marks a tile's content visible if it is already available, or records a request for it.
    ///
    /// - Returns: `true` when the content is accounted for, whether that means drawn, descended
    ///   into as a sub-tileset, or known to contain nothing.
    private func present(
        uri: String,
        transform: simd_double4x4,
        cameraPosition: SIMD3<Float>,
        screenHeight: Float,
        fov: Float,
        visibleURIs: inout Set<String>,
        requests: inout [ContentRequest],
        stats: inout TraversalStats,
        depth: Int
    ) -> Bool {
        if loadedEntities[uri] != nil {
            visibleURIs.insert(uri)
            stats.rendered += 1
            return true
        }

        // Fetched already and found to hold nothing we can draw. Treated as covered so an
        // ancestor does not keep standing in for geometry that will never arrive.
        if barrenTiles.contains(uri) { return true }

        if let subTileset = subTilesets[uri] {
            return traverseTile(
                subTileset.root,
                parentTransform: transform,
                cameraPosition: cameraPosition,
                screenHeight: screenHeight,
                fov: fov,
                visibleURIs: &visibleURIs,
                requests: &requests,
                stats: &stats,
                depth: depth + 1
            )
        }

        requests.append(ContentRequest(uri: uri, transform: transform))
        return false
    }

    // MARK: - Loading

    /// Fetches requested content concurrently, up to `maxConcurrentLoads` at a time.
    private func fetch(_ requests: [ContentRequest], into parentEntity: Entity) async {
        let pending = requests.filter { !inFlight.contains($0.uri) }
        guard !pending.isEmpty else { return }

        // Capped so one pass cannot monopolise the network while the camera moves on; whatever
        // is left over is requested again by the next traversal.
        let batch = Array(pending.prefix(max(1, maxConcurrentLoads) * 4))
        for request in batch { inFlight.insert(request.uri) }

        let provider = self.provider
        await withTaskGroup(of: (ContentRequest, Data?).self) { group in
            var next = 0
            let width = min(max(1, maxConcurrentLoads), batch.count)

            while next < width {
                let request = batch[next]
                group.addTask { (request, try? await provider.fetchTileContent(uri: request.uri)) }
                next += 1
            }

            for await (request, data) in group {
                await integrate(request: request, data: data, into: parentEntity)

                if next < batch.count {
                    let follow = batch[next]
                    group.addTask { (follow, try? await provider.fetchTileContent(uri: follow.uri)) }
                    next += 1
                }
            }
        }
    }

    /// Turns fetched bytes into either a resolved sub-tileset or a drawable entity.
    private func integrate(request: ContentRequest, data: Data?, into parentEntity: Entity) async {
        inFlight.remove(request.uri)

        guard let data else {
            barrenTiles.insert(request.uri)
            logger.debug("Failed to fetch tile: \(request.uri)")
            return
        }

        if Self.isJSONData(data) {
            if let subTileset = try? JSONDecoder().decode(TilesetJSON.self, from: data) {
                subTilesets[request.uri] = subTileset
            } else {
                barrenTiles.insert(request.uri)
            }
            return
        }

        guard let tileLoader,
              let entity = try? await tileLoader.loadTileFromData(
                  data, uri: request.uri, transform: request.transform
              )
        else {
            // Unsupported format, or every triangle fell outside the boundary. Either way it is
            // recorded so the next traversal does not fetch it all over again.
            barrenTiles.insert(request.uri)
            return
        }

        // Hidden until a traversal selects it, so a tile cannot flash in at the wrong level.
        entity.isEnabled = false
        parentEntity.addChild(entity)
        loadedEntities[request.uri] = entity
        framesSinceVisible[request.uri] = 0
    }

    /// Shows exactly the tiles the traversal selected and hides the rest.
    ///
    /// Loading a tile is not the same as showing it. A coarse ancestor is drawn while its children
    /// stream in, and must be hidden the moment they can cover for it — otherwise it sits on top
    /// of the very detail it was standing in for, which looks like the tileset never refines.
    /// Hidden tiles stay loaded, so switching back is free.
    private func applyVisibility(_ visibleURIs: Set<String>) {
        for (uri, entity) in loadedEntities {
            let shouldShow = visibleURIs.contains(uri)
            if entity.isEnabled != shouldShow {
                entity.isEnabled = shouldShow
            }
        }
    }

    /// Ages out tiles that have not been seen recently, but only once over budget.
    ///
    /// Evicting purely on age discards tiles the camera is about to swing back to, and reloading
    /// them is what makes a tileset flicker.
    private func evict(keeping visibleURIs: Set<String>) {
        for uri in loadedEntities.keys {
            framesSinceVisible[uri] = visibleURIs.contains(uri) ? 0 : (framesSinceVisible[uri] ?? 0) + 1
        }

        guard loadedEntities.count > maxRetainedTiles else { return }

        let stale = framesSinceVisible
            .filter { !visibleURIs.contains($0.key) && $0.value > evictionFrameThreshold }
            .sorted { $0.value > $1.value }

        for (uri, _) in stale {
            guard loadedEntities.count > maxRetainedTiles else { break }
            loadedEntities.removeValue(forKey: uri)?.removeFromParent()
            framesSinceVisible.removeValue(forKey: uri)
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
