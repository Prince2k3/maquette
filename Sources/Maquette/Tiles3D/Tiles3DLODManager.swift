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
    /// How far beyond the outline the diorama can be panned, as a fraction of its radius.
    private let panRange: Float
    /// Outline to cut tile geometry to as it loads, or `nil` to leave tiles whole.
    ///
    /// Moves when the diorama pans; see `setClipPrism`.
    private var clipPrism: BoundaryPrism?
    private let logger = Logger(subsystem: "com.maquette", category: "Tiles3DLODManager")

    private var rootTileset: TilesetJSON?
    private var loadedEntities: [String: ModelEntity] = [:]
    private var tileLoader: Tile3DLoader?
    /// Each tile's geometry as it arrived, kept only while the diorama can pan.
    private var sourceGeometry: [String: Tiles3DSourceGeometry] = [:]
    /// Each tile's drawable buffer, rewritten in place every time the outline moves past it.
    private var tileMeshes: [String: Tiles3DTileMesh] = [:]
    /// Where the cut is assembled, held across tiles so its buffers are allocated once rather than
    /// once per tile per pan step.
    private var clipResult = Tiles3DClipper.Result()
    /// Loaded tiles the outline currently cuts away entirely.
    ///
    /// Held rather than forgotten because panning is exactly what brings them back, but never
    /// enabled — an entity with no mesh draws nothing, and enabling it would only confuse the
    /// visible-tile scans the datum and the cut wall are built from.
    private var clippedAway: Set<String> = []
    /// The tiles the last traversal chose to draw, whether or not they currently hold geometry.
    ///
    /// Retained because a pan changes which of them survive the outline without running a traversal:
    /// the camera has not moved, so nothing recomputes what should be on screen. Re-cutting alone
    /// cannot show a tile — `apply` hides one that clips to nothing but never reveals one that comes
    /// back — so without this a pan could only ever eat the model away, never slide new ground into
    /// it, which is the entire point of the gesture.
    private var selectedURIs: Set<String> = []
    /// Bumped every time the outline moves, so a tile that was being cut while it moved can tell.
    private var clipGeneration = 0
    private var framesSinceVisible: [String: Int] = [:]
    private var subTilesets: [String: TilesetJSON] = [:]
    private var hasLoggedFirstTraversal = false
    /// Content fetched successfully that holds nothing drawable — an unsupported format, or
    /// geometry entirely outside the boundary. Remembered so it is not re-fetched every traversal,
    /// and treated as covered: nothing will ever appear there, so an ancestor standing in would
    /// only draw coarse geometry over ground that is meant to be empty.
    private var emptyTiles: Set<String> = []

    /// Content whose fetch failed, with how many times it has been tried.
    ///
    /// Deliberately *not* treated as covered. Conflating a failed fetch with an empty tile is what
    /// turns a handful of failing requests into a blank model: the traversal believes the area is
    /// accounted for, so the ancestor that could have stood in stays hidden.
    private var failedTiles: [String: Int] = [:]
    /// Content fetches currently in flight, so a tile is not requested twice.
    private var inFlight: Set<String> = []

    /// Set when a fetch is rejected because the provider's session has expired.
    private var needsSessionRenewal = false
    private var lastSessionRenewal: Date?
    /// Renewals since the last tile actually arrived, so a permanent failure stops spending.
    private var renewalsWithoutProgress = 0

    /// Shortest gap between session renewals.
    ///
    /// Each renewal is a billable root request, so a provider rejecting tiles for some reason other
    /// than expiry must not be able to spend in a loop.
    public var minimumSessionRenewalInterval: TimeInterval = 60

    /// Renewals attempted without a single tile arriving before renewing is abandoned.
    public var maximumRenewalsWithoutProgress = 3

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

    /// How many times a failing tile is retried before the traversal stops asking for it.
    public var maximumLoadAttempts: Int = 3

    /// Tiles retained before unseen ones start being evicted.
    ///
    /// This is a memory budget, not a limit on how much may be drawn. An earlier cap of
    /// `maxConcurrentLoads * 10` silently stopped loading anything once forty tiles existed.
    public var maxRetainedTiles: Int = 600

    // MARK: - Streaming Progress

    /// Tiles currently held as drawable geometry.
    public private(set) var loadedTileCount = 0

    /// Content the most recent traversal asked for and does not yet have.
    public private(set) var pendingTileCount = 0

    /// How far the most recent update got. Starts `incomplete`, since nothing has loaded yet.
    public private(set) var refinement: Refinement = .incomplete

    /// Records what the latest traversal saw, for anything observing the stream's progress.
    ///
    /// Assignments are guarded on inequality because Observation notifies on every write, not
    /// every change, and these are read from view bodies that in turn drive the next update.
    private func publishProgress(pending: Int) {
        if loadedTileCount != loadedEntities.count { loadedTileCount = loadedEntities.count }
        if pendingTileCount != pending { pendingTileCount = pending }
    }

    init(
        provider: any Tiles3DProvider,
        ecefConverter: ECEFConverter,
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        clipPrism: BoundaryPrism? = nil,
        panRange: Float = 0
    ) {
        self.provider = provider
        self.ecefConverter = ecefConverter
        self.center = center
        self.radiusMeters = radiusMeters
        self.clipPrism = clipPrism
        self.panRange = max(0, panRange)
    }

    /// How far out tiles are kept, which is further than the outline reaches when panning.
    ///
    /// The cull is what decides a tile is irrelevant, and on a pannable diorama the ground just
    /// outside the outline is not irrelevant at all — it is what slides into view. Culling to the
    /// outline alone would leave the model with a hard edge that never fills in, in whichever
    /// direction the user drags.
    private var cullRadiusMeters: Double {
        radiusMeters * Double(1 + panRange)
    }

    /// Whether tiles keep their pre-clip geometry, so a pan can cut them somewhere new.
    private var canPan: Bool { panRange > 0 && clipPrism != nil }

    /// Loads the root tileset and prepares for tile management.
    func start() async throws {
        let tileset = try await provider.fetchTileset()
        self.rootTileset = tileset
        self.tileLoader = Tile3DLoader(
            provider: provider,
            ecefConverter: ecefConverter,
            clipPrism: clipPrism,
            retainsSourceGeometry: canPan
        )
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

    /// How far an update got towards drawing everything the camera can see.
    public enum Refinement {
        /// Every visible tile is loaded and shown. Nothing more to do from here.
        case converged
        /// Content is still missing and still arriving — calling again makes progress.
        case incomplete
        /// Content is still missing but the last passes brought nothing new. Asking again with the
        /// same camera would repeat identical requests, so it takes a change to move this on.
        case stalled
    }

    /// Updates visible tiles based on camera position.
    ///
    /// Traversal only reads what is already known — it never waits on the network. Anything
    /// missing is recorded as a request and fetched afterwards, concurrently. Fetching inline
    /// made a single pass take as long as every tile it touched, so the view spent essentially
    /// all its time part-loaded.
    ///
    /// One call is bounded — `maxPassesPerUpdate` passes of at most `maxConcurrentLoads * 4`
    /// fetches each — so a dense view will not finish in one. The return value says so, and the
    /// caller is expected to keep asking; see `Tiles3DEntity.requestLODUpdate`.
    func update(
        parentEntity: Entity,
        cameraPosition: SIMD3<Float>,
        screenHeight: Float,
        fov: Float
    ) async -> Refinement {
        guard rootTileset != nil else { return finish(.converged) }

        // Each pass can only descend as far as what is already resolved: a sub-tileset has to be
        // fetched before its children are even visible to the traversal. So a pass reaches one
        // level deeper than the last, and the update drives itself until coverage stops improving
        // rather than waiting for the view to ask again.
        var stalled = false
        for _ in 0..<maxPassesPerUpdate {
            let requests = selectVisibleTiles(
                cameraPosition: cameraPosition,
                screenHeight: screenHeight,
                fov: fov
            )
            if requests.isEmpty { return finish(.converged) }

            let loadedBefore = loadedEntities.count
            let resolvedBefore = subTilesets.count + emptyTiles.count + failedTiles.count
            await fetch(requests, into: parentEntity)

            // Nothing arrived, so another pass would ask for exactly the same things.
            if loadedEntities.count == loadedBefore,
               subTilesets.count + emptyTiles.count + failedTiles.count == resolvedBefore {
                stalled = true
                break
            }
        }

        // Tiles are added hidden and only shown once a traversal picks them, so whatever the last
        // fetch brought in needs one more selection. Without it the newest geometry stays
        // invisible until something else happens to trigger an update — which looks like the view
        // filling in while the camera moves and emptying again when it stops.
        let remaining = selectVisibleTiles(
            cameraPosition: cameraPosition,
            screenHeight: screenHeight,
            fov: fov
        )
        if remaining.isEmpty { return finish(.converged) }
        return finish(stalled ? .stalled : .incomplete)
    }

    /// Records how the update ended, so anything observing the stream knows whether to keep waiting.
    private func finish(_ result: Refinement) -> Refinement {
        if refinement != result { refinement = result }
        return result
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
            inheritedRefine: .replace,
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
        publishProgress(pending: requests.count)

        if !hasLoggedFirstTraversal || requests.isEmpty {
            logger.debug("LOD: visited=\(stats.visited) culled=\(stats.culled) refined=\(stats.refined) rendered=\(stats.rendered) requested=\(requests.count) noContent=\(stats.noContent) empty=\(self.emptyTiles.count) failed=\(self.failedTiles.count) subtilesets=\(self.subTilesets.count) depth=\(stats.maxDepth) loaded=\(self.loadedEntities.count)")
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
        inheritedRefine: RefinementStrategy,
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
        if let bv, !bv.intersects(center: center, radiusMeters: cullRadiusMeters) {
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

            // The spec requires refinement on the root and makes it optional elsewhere: "When
            // omitted, a tile inherits the refinement type of its parent." Defaulting to REPLACE
            // instead is wrong in a way that erases geometry — a tile meant to be ADD would have
            // its parent hidden, so if its children fail or are empty, nothing is drawn at all.
            let refine = tile.refine ?? inheritedRefine

            var childrenCovered = true
            for child in children {
                // Every child is visited even once coverage is known to be incomplete, because
                // short-circuiting would leave their content unrequested and never loading.
                let covered = traverseTile(
                    child,
                    parentTransform: tileTransform,
                    inheritedRefine: refine,
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
            var parentDrawn = false
            let standsIn = refine == .add
                || (!childrenCovered && canStandIn(screenSpaceError: sse))
            if standsIn, let uri = tile.content?.uri {
                parentDrawn = present(
                    uri: uri,
                    transform: tileTransform,
                    inheritedRefine: refine,
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
            inheritedRefine: inheritedRefine,
            cameraPosition: cameraPosition,
            screenHeight: screenHeight,
            fov: fov,
            visibleURIs: &visibleURIs,
            requests: &requests,
            stats: &stats,
            depth: depth
        )
    }

    /// Whether a tile is close enough to the detail being asked for to stand in for it.
    ///
    /// Standing in is only worth doing while the substitute still resembles what it replaces. One
    /// or two levels up the tree that holds — the ground is in the right place, just softer, which
    /// is what progressive refinement is meant to look like. Further up it stops being a rougher
    /// version of the answer and becomes a different one: on Half Dome the leaves sit at a
    /// geometric error of 16 m, and the ancestor still standing in for them was at 1,027 m, a tile
    /// with over a kilometre of relief in it drawn across a chunk 2.8 km wide. Cut to the outline
    /// it read as a tilted, smeared wedge hanging off the model's left side.
    ///
    /// Excluding it is not only cosmetic. The ground datum and the tray are both measured from the
    /// lowest visible geometry, and that one tile bottomed out 135 m below every other tile on
    /// screen — so the tray was placed 135 m too low and the model floated in a visible gap above
    /// the thing it is supposed to be resting on. Seventy-six tiles agreed on where the ground was
    /// and the seventy-seventh overruled them, because a minimum is decided by its outlier.
    ///
    /// The bound is in screen-space error rather than metres, which is the same measure the
    /// traversal refines by: it already accounts for camera distance and for how coarse this
    /// particular tileset's levels happen to be. Four times the threshold is roughly two levels,
    /// since each level about halves the error. Past that the hole is the better of the two —
    /// there is a loading indicator for ground that has not arrived, and none for ground in the
    /// wrong place.
    private func canStandIn(screenSpaceError: Double) -> Bool {
        screenSpaceError <= screenSpaceErrorThreshold * Self.standInErrorTolerance
    }

    /// How many times the refinement threshold a stand-in's screen-space error may reach.
    private static let standInErrorTolerance: Double = 4

    /// Marks a tile's content visible if it is already available, or records a request for it.
    ///
    /// - Returns: `true` when the content is accounted for, whether that means drawn, descended
    ///   into as a sub-tileset, or known to contain nothing.
    private func present(
        uri: String,
        transform: simd_double4x4,
        inheritedRefine: RefinementStrategy,
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

        // Fetched and genuinely empty: covered, because nothing is meant to appear here.
        if emptyTiles.contains(uri) { return true }

        // Failed too many times. Reported as uncovered so an ancestor draws in its place rather
        // than leaving a hole, but no longer requested.
        if let attempts = failedTiles[uri], attempts >= maximumLoadAttempts { return false }

        if let subTileset = subTilesets[uri] {
            return traverseTile(
                subTileset.root,
                parentTransform: transform,
                inheritedRefine: inheritedRefine,
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
        func load(_ request: ContentRequest) -> @Sendable () async -> (ContentRequest, Result<Data, any Error>) {
            {
                do { return (request, .success(try await provider.fetchTileContent(uri: request.uri))) }
                catch { return (request, .failure(error)) }
            }
        }

        await withTaskGroup(of: (ContentRequest, Result<Data, any Error>).self) { group in
            var next = 0
            let width = min(max(1, maxConcurrentLoads), batch.count)

            while next < width {
                group.addTask(operation: load(batch[next]))
                next += 1
            }

            for await (request, result) in group {
                await integrate(request: request, result: result, into: parentEntity)

                if next < batch.count {
                    group.addTask(operation: load(batch[next]))
                    next += 1
                }
            }
        }

        // A dead session rejects every request alike, so one renewal covers the whole batch.
        if needsSessionRenewal { await renewSession() }
    }

    /// Establishes a fresh session after the old one expired.
    ///
    /// Google's session token outlives neither the view nor the root cache: measured during
    /// development, a root twenty minutes old already had tiles rejected with 400. Until this
    /// existed there was no way back from that. The token was cleared, nothing ever re-fetched the
    /// root, and every request from then on failed — so the model held whatever it had already
    /// drawn and lost the rest as tiles were evicted or the camera moved somewhere new. It looked
    /// like content appearing and then disappearing some minutes later.
    ///
    /// This costs one billable request, because Google bills the root and nothing else. That is
    /// the price of a session that outlives its token, so it is rationed: no more often than
    /// `minimumSessionRenewalInterval`, and not at all once renewals stop bringing tiles back.
    private func renewSession() async {
        needsSessionRenewal = false

        guard renewalsWithoutProgress < maximumRenewalsWithoutProgress else { return }
        if let last = lastSessionRenewal, Date().timeIntervalSince(last) < minimumSessionRenewalInterval {
            return
        }
        lastSessionRenewal = Date()
        renewalsWithoutProgress += 1

        // The returned tileset is deliberately discarded. Its URIs name the new session, and
        // adopting them would re-key every tile already loaded, so the whole model would reload as
        // duplicates. The token is what was needed, and `fetchTileContent` now applies the live one
        // to the URIs already held.
        guard (try? await provider.fetchTileset()) != nil else {
            logger.error("Session renewal failed; no further tiles will load")
            return
        }

        // The rejections were the session's doing, not the tiles', so their strikes are wiped —
        // otherwise a single expiry retires everything that happened to be in flight.
        failedTiles.removeAll()
        logger.info("Renewed the tile session after expiry")
    }

    /// Turns fetched bytes into either a resolved sub-tileset or a drawable entity.
    private func integrate(
        request: ContentRequest,
        result: Result<Data, any Error>,
        into parentEntity: Entity
    ) async {
        inFlight.remove(request.uri)

        let data: Data
        switch result {
        case .success(let value):
            data = value
            renewalsWithoutProgress = 0
        case .failure(let error):
            // An expired session rejects every tile alike. Charging that to the tile would retire
            // perfectly good content after three rounds and leave holes nothing ever fills, so the
            // session is renewed and the tile asked for again with its record intact.
            if let dioramaError = error as? DioramaError,
               case .sessionExpired = dioramaError {
                needsSessionRenewal = true
            } else if let dioramaError = error as? DioramaError,
                      case .authenticationFailed = dioramaError {
                // How the same expiry presents once the token has already been cleared.
            } else {
                failedTiles[request.uri, default: 0] += 1
            }
            logger.debug("Failed to fetch tile: \(request.uri) — \(error.localizedDescription)")
            return
        }

        if Self.isJSONData(data) {
            if let subTileset = try? JSONDecoder().decode(TilesetJSON.self, from: data) {
                subTilesets[request.uri] = subTileset
            } else {
                emptyTiles.insert(request.uri)
            }
            return
        }

        // A tile takes several awaits to decode and cut, and the outline can move across every one
        // of them — leaving geometry cut to an outline that is no longer where it was. Noted here
        // rather than compared afterwards, because by then the prism that did the cutting is gone.
        let generationAtLoad = clipGeneration

        guard let tileLoader,
              let loaded = try? await tileLoader.loadTileFromData(
                  data, uri: request.uri, transform: request.transform
              )
        else {
            // Unsupported format, or every triangle fell outside the boundary. Either way the
            // content arrived, so this is genuinely empty rather than a failure.
            emptyTiles.insert(request.uri)
            return
        }

        // Hidden until a traversal selects it, so a tile cannot flash in at the wrong level.
        let entity = loaded.entity
        entity.isEnabled = false
        parentEntity.addChild(entity)
        loadedEntities[request.uri] = entity
        framesSinceVisible[request.uri] = 0
        if let source = loaded.source {
            sourceGeometry[request.uri] = source
            // Adopted rather than recreated, so the first re-cut writes into the buffer the tile is
            // already being drawn from.
            tileMeshes[request.uri] = loaded.mesh
            // The loader hands back a model-less entity when the outline took everything, so that
            // panning towards it can still find it. Nothing to draw until then.
            if entity.model == nil { clippedAway.insert(request.uri) }
            if generationAtLoad != clipGeneration {
                apply(clipPrism, to: entity, from: source, uri: request.uri)
            }
        }
    }

    // MARK: - Panning

    /// Moves the outline the tiles are cut to, re-cutting only what the move actually changes.
    ///
    /// Almost every tile is either still wholly inside the outline or still wholly outside it after
    /// a pan step, and neither needs touching — the container the tiles hang from carries them.
    /// Only the rim, where the outline's edge crosses a tile, has a different answer than before.
    func setClipPrism(_ prism: BoundaryPrism?) {
        let previous = clipPrism
        clipPrism = prism
        tileLoader?.clipPrism = prism
        clipGeneration &+= 1

        var recut = 0
        let started = ContinuousClock.now
        for (uri, source) in sourceGeometry {
            guard let entity = loadedEntities[uri] else { continue }
            guard source.needsRecut(from: previous, to: prism) else { continue }
            recut += 1
            apply(prism, to: entity, from: source, uri: uri)
        }
        // Re-decide what is on screen: the re-cut above has just changed which tiles hold geometry.
        applyVisibility(selectedURIs)
        if recut > 0 {
            let elapsed = (ContinuousClock.now - started).milliseconds
            logger.debug("""
                Re-cut \(recut) of \(self.sourceGeometry.count) tiles \
                against the moved outline in \(String(format: "%.1f", elapsed)) ms
                """)
        }
    }

    /// Rebuilds one tile's drawable geometry against the outline where it now stands.
    private func apply(
        _ prism: BoundaryPrism?,
        to entity: ModelEntity,
        from source: Tiles3DSourceGeometry,
        uri: String
    ) {
        // Cut straight into the layout the buffer is drawn from, reusing the arrays the last tile
        // filled: a pan re-cuts a couple of hundred tiles in a row, and they are all the same shape
        // of work.
        if let prism {
            Tiles3DClipper.clip(
                descriptors: source.descriptors,
                placement: source.placement,
                to: prism,
                into: &clipResult
            )
        } else {
            Tiles3DClipper.pack(descriptors: source.descriptors, into: &clipResult)
        }
        let cutEdges = clipResult.cutEdges

        // Written into a buffer RealityKit already holds rather than compiled into a new asset. A
        // pan re-cuts a couple of hundred tiles at once, and `MeshResource.generate` measured about
        // half the cost of a step doing exactly that work over again every time.
        let buffer: Tiles3DTileMesh
        if let existing = tileMeshes[uri] {
            buffer = existing
        } else if let created = try? Tiles3DTileMesh(vertexCapacity: 1, indexCapacity: 1) {
            buffer = created
            tileMeshes[uri] = created
        } else {
            entity.model = nil
            entity.isEnabled = false
            entity.components.remove(Tiles3DCutEdgeComponent.self)
            clippedAway.insert(uri)
            return
        }

        let outcome = (try? buffer.write(
            vertices: clipResult.vertices,
            indices: clipResult.indices,
            bounds: clipResult.bounds
        )) ?? .empty
        guard outcome != .empty else {
            entity.model = nil
            entity.isEnabled = false
            entity.components.remove(Tiles3DCutEdgeComponent.self)
            clippedAway.insert(uri)
            return
        }

        // The clip bakes placement into the vertices, so an entity holding cut geometry carries no
        // transform of its own — and one that previously held whole geometry has to give up the
        // transform it was placed with.
        //
        // The `ModelComponent` only has to be replaced when the buffer grew and handed back a new
        // `MeshResource`; otherwise the one the entity holds already points at the mesh that was
        // just rewritten.
        if outcome == .regrown || entity.model == nil {
            entity.model = ModelComponent(mesh: buffer.resource, materials: [source.material])
        }
        entity.transform = Transform(
            matrix: prism == nil ? source.placement : matrix_identity_float4x4
        )
        if cutEdges.isEmpty {
            entity.components.remove(Tiles3DCutEdgeComponent.self)
        } else {
            _ = Tiles3DCutEdgeRegistration.perform
            entity.components.set(Tiles3DCutEdgeComponent(edges: cutEdges))
        }
        clippedAway.remove(uri)
    }

    /// Shows exactly the tiles the traversal selected and hides the rest.
    ///
    /// Loading a tile is not the same as showing it. A coarse ancestor is drawn while its children
    /// stream in, and must be hidden the moment they can cover for it — otherwise it sits on top
    /// of the very detail it was standing in for, which looks like the tileset never refines.
    /// Hidden tiles stay loaded, so switching back is free.
    private func applyVisibility(_ visibleURIs: Set<String>) {
        selectedURIs = visibleURIs
        for (uri, entity) in loadedEntities {
            let shouldShow = visibleURIs.contains(uri) && !clippedAway.contains(uri)
            if entity.isEnabled != shouldShow {
                entity.isEnabled = shouldShow
            }
        }
    }

    /// Ages out tiles that have not been seen recently, but only once over budget.
    ///
    /// Evicting purely on age discards tiles the camera is about to swing back to, and reloading
    /// them is what makes a tileset flicker. Age alone cannot be the whole rule either. The counter
    /// advances per traversal, and traversals only happen while the camera moves, so a view that
    /// settles ages nothing: measured on Half Dome, twenty-five minutes of orbiting produced 65
    /// traversals and 689 retained tiles against a budget of 600, with not one eviction — nothing
    /// could possibly have gone unseen for the required 60. Over budget the oldest hidden tiles
    /// therefore go regardless of how recently they were seen; the threshold decides who is
    /// preferred, not whether anyone is eligible.
    private func evict(keeping visibleURIs: Set<String>) {
        for uri in loadedEntities.keys {
            framesSinceVisible[uri] = visibleURIs.contains(uri) ? 0 : (framesSinceVisible[uri] ?? 0) + 1
        }

        // Only hidden tiles are evictable, so the budget has to be read against them. A visible set
        // larger than the budget would otherwise put this on a treadmill: each pass evicts the few
        // hidden tiles, the next asks for them again, and nothing is reclaimed because the tiles
        // holding the memory are the ones being drawn. The Pan 3D preset renders 699 against a
        // budget of 600, so it sits exactly in that regime once settled. Raising the floor to the
        // visible count costs nothing — those tiles were staying either way.
        let effectiveBudget = max(maxRetainedTiles, visibleURIs.count)
        guard loadedEntities.count > effectiveBudget else { return }

        let hidden = framesSinceVisible
            .filter { !visibleURIs.contains($0.key) && loadedEntities[$0.key] != nil }
            .sorted { $0.value > $1.value }

        var removed = 0
        for (uri, age) in hidden {
            guard loadedEntities.count > effectiveBudget else { break }
            // Past the threshold this is routine ageing. Under it, the budget is being enforced,
            // which is worth saying: a view evicting tiles it saw moments ago will reload them, and
            // that is the flicker the threshold exists to avoid.
            if age <= evictionFrameThreshold {
                logger.debug("Over the tile budget with nothing stale; evicting \(uri) last seen \(age) traversals ago")
            }
            loadedEntities.removeValue(forKey: uri)?.removeFromParent()
            framesSinceVisible.removeValue(forKey: uri)
            sourceGeometry.removeValue(forKey: uri)
            tileMeshes.removeValue(forKey: uri)
            clippedAway.remove(uri)
            selectedURIs.remove(uri)
            removed += 1
        }
        if removed > 0 {
            logger.debug("Evicted \(removed) tiles; \(self.loadedEntities.count) retained")
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

extension Duration {
    /// This duration in milliseconds.
    ///
    /// `components` splits a duration into whole seconds *and* the attosecond remainder, so reading
    /// the remainder alone silently discards every whole second. That is a quiet way to be wrong:
    /// a measurement only crosses a second when something is slow, so the readings that matter most
    /// are exactly the ones that come back short — a ten-second pan step logged as 871 ms.
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
