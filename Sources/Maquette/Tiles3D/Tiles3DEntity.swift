import CoreLocation
import Foundation
import RealityKit
import os

/// A RealityKit Entity that renders OGC 3D Tiles content.
///
/// Manages a tree of child entities, each representing a loaded tile's mesh.
/// Supports Google Photorealistic 3D Tiles and Cesium ion sources.
@MainActor
public class Tiles3DEntity: Entity {
    private let lodManager: Tiles3DLODManager
    private let logger = Logger(subsystem: "com.maquette", category: "Tiles3DEntity")

    /// Scale converting real-world meters to diorama physical meters.
    private let geographicScale: Float

    /// Throttle interval between LOD updates.
    private static let lodUpdateInterval: TimeInterval = 0.2
    private var lastLODUpdateTime: Date?
    private var isLODUpdating = false

    /// Pause between self-driven refinement rounds.
    ///
    /// Shorter than the throttle, which exists to stop a moving camera flooding the traversal.
    /// Refinement is not being driven by a gesture, so it should settle promptly.
    private static let refinementInterval: Duration = .milliseconds(50)

    /// Self-driven rounds a single request may run before it goes quiet again.
    ///
    /// A backstop, not a budget: `update` stops on its own once coverage is complete or stops
    /// improving. This only bounds the pathological case of a view so dense that it never settles.
    private static let maxRefinementRounds = 24

    /// Where the camera was when the view last asked, in this entity's local space.
    ///
    /// Kept so the self-driven rounds refine towards the *current* camera rather than the one that
    /// happened to start them.
    private var latestViewpoint: Viewpoint?

    /// The camera parameters a traversal needs.
    private struct Viewpoint {
        let cameraPosition: SIMD3<Float>
        let screenHeight: Float
        let fov: Float
    }

    /// The outline the model is cut to, and what it rests on.
    private let style: Tiles3DStyle
    private let boundary: DioramaBoundary
    /// The outline raised into the prism tiles were cut against, in the geometry's own space.
    ///
    /// Kept because the cut wall is built from the segments that clip produced, which are in that
    /// space too — so the wall, its perimeter texturing, and its outward normals all come from one
    /// consistent source rather than being re-derived from the diorama-space outline.
    private let clipPrism: BoundaryPrism?
    /// The tray beneath the model, if the style asks for one.
    public private(set) var base: Entity?
    /// The wall closing the model's cut silhouette, if the style asks for one.
    public private(set) var cutWall: Entity?
    /// What the wall currently standing was built from, so it is not rebuilt for nothing.
    private var placedWall: (edgeCount: Int, floorY: Float)?
    /// Lowest point seen across loaded tiles, in this entity's local space.
    ///
    /// Photogrammetry has no known floor until geometry arrives, and level-of-detail refinement
    /// can reveal lower ground later, so the tray settles downward as tiles load rather than
    /// being positioned once up front.
    private var lowestLoadedY: Float?

    /// Creates a 3D Tiles entity from a provider.
    /// - Parameters:
    ///   - provider: The 3D Tiles data source.
    ///   - center: Geographic center of the diorama.
    ///   - radiusMeters: Radius of the diorama in meters.
    ///   - physicalDiameter: The diorama's physical diameter in meters.
    ///   - boundary: The outline to cut the model to, in diorama meters.
    ///   - style: How the model is bounded and what it rests on.
    public init(
        provider: any Tiles3DProvider,
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        physicalDiameter: Float,
        boundary: DioramaBoundary,
        style: Tiles3DStyle = .standard
    ) async throws {
        let ecefConverter = ECEFConverter(origin: center)
        let geographicScale = physicalDiameter / Float(radiusMeters * 2.0)

        // Tile geometry is in real-world meters while the outline is in diorama meters, and the
        // conversion rides on this entity's scale, so the prism is built in the geometry's space.
        let prism = style.clipsToBoundary
            ? BoundaryPrism(boundary: boundary, scale: geographicScale)
            : nil

        self.lodManager = Tiles3DLODManager(
            provider: provider,
            ecefConverter: ecefConverter,
            center: center,
            radiusMeters: radiusMeters,
            clipPrism: prism
        )
        self.lodManager.screenSpaceErrorThreshold = style.detailThreshold
        self.geographicScale = geographicScale
        self.style = style
        self.boundary = boundary
        self.clipPrism = prism
        super.init()
        self.name = "Tiles3D"
        self.scale = SIMD3<Float>(repeating: geographicScale)

        try await lodManager.start()
        logger.info("3D Tiles entity initialized (scale=\(self.geographicScale), clipped=\(prism != nil)): \(provider.attribution)")
    }

    /// How much of the model has arrived.
    ///
    /// This entity exists as soon as its root tileset does, with nothing in it. Everything visible
    /// arrives afterwards, over seconds to minutes depending on the region — so a caller that
    /// treats construction as "loaded" is reporting a model that is not there yet.
    public var streamingProgress: DioramaStreamingProgress {
        DioramaStreamingProgress(
            tilesLoaded: lodManager.loadedTileCount,
            tilesPending: lodManager.pendingTileCount,
            // `stalled` is not progress: the same requests would go out again unchanged, so it
            // takes a camera move to shift, and an indicator left spinning on it never stops.
            isStreaming: lodManager.refinement == .incomplete
        )
    }

    /// The underside of the model that is actually on screen, in this entity's local space.
    ///
    /// Three things make the naive measurement wrong. Measuring every child includes the tray and
    /// the cut wall, which are built *from* this measurement — so each update would chase its own
    /// output downward by a thickness. Measuring
    /// tiles that are loaded but hidden includes superseded coarse ancestors, which span far more
    /// ground — and therefore reach far lower — than the detail that replaced them. And because
    /// this is a minimum, a single child in the wrong place decides it on its own.
    ///
    /// So implausible ground is discarded rather than trusted. Geometry cannot be kilometres below
    /// the ellipsoid and still be terrain, and taking `min` over it unguarded once dropped the
    /// datum by an Earth diameter on the strength of one tile.
    private func lowestVisibleY() -> Float? {
        var candidate = Float.greatestFiniteMagnitude
        for child in children where child.isEnabled && !Self.derivedNames.contains(child.name) {
            let bounds = child.visualBounds(relativeTo: self)
            guard bounds.min.y.isFinite,
                  bounds.min.y > -BoundingVolume.terrainElevationBound else { continue }
            candidate = min(candidate, bounds.min.y)
        }

        return candidate < .greatestFiniteMagnitude ? candidate : nil
    }

    /// Drops the model so its lowest ground sits at diorama Y = 0.
    ///
    /// 3D Tiles arrive positioned against the WGS84 ellipsoid, and this entity's local origin is
    /// at ellipsoid height zero, so terrain loads as far above the origin as it is above sea
    /// level. Everything outside this pipeline is built on the convention that Y = 0 is the lowest
    /// terrain in the region — the camera aims at it, markers and the water plane measure from it
    /// — so the photorealistic path has to meet that convention rather than the other way round.
    /// Without this a chunk of the Sierra hangs two kilometres over the table and frames off the
    /// top of the screen, while at sea level the offset is nil and nothing looks wrong.
    ///
    /// Re-measured every refinement round rather than frozen after the first. Early rounds have
    /// only coarse ancestors, which span far more ground than the chunk and so reach lower than it
    /// does; freezing there would push the model up by the difference. It settles when refinement
    /// does, alongside the tray.
    private func anchorGround() {
        guard let lowest = lowestVisibleY() else { return }
        position.y = -lowest * geographicScale
    }

    /// How far the underside has to move before anything measured from it is rebuilt.
    ///
    /// A quarter of the tray's thickness, expressed in this entity's space. Both the tray and the
    /// cut wall are built from the datum and both are expensive to rebuild, so they share one
    /// threshold — drifting apart would let the wall chase a datum the tray had ignored, and the
    /// gap between them is exactly what this is all for.
    private var datumRebuildThreshold: Float {
        let thickness: Float
        if case .tray(_, let value, _) = style.base {
            thickness = value
        } else {
            thickness = 0.02
        }
        return max(thickness, .ulpOfOne) / max(geographicScale, .ulpOfOne) * 0.25
    }

    /// Repositions the tray to sit just beneath the model that is actually on screen.
    private func updateBase() {
        guard case .tray(let color, let thickness, let inset) = style.base else { return }
        guard let candidate = lowestVisibleY() else { return }

        // Tracked in both directions, since refinement can raise the underside as well as lower
        // it, but only rebuilt on a meaningful move so the tray does not jitter every update.
        if let placed = lowestLoadedY, abs(candidate - placed) < datumRebuildThreshold { return }
        // Geometry here is pre-scale, but `DioramaBase` works in diorama meters, so the tray is
        // built in diorama space and divided back into this entity's space.
        //
        // Built before the old one is taken away, and nothing is committed until it succeeds. The
        // other order loses the tray outright on a failed build: it has already been detached, and
        // `lowestLoadedY` has already moved, so the next update sees no meaningful change and never
        // tries again.
        let trayTop = candidate * geographicScale
        guard let entity = try? DioramaBase.generate(
            style: .plinth(color: color, height: thickness, inset: inset),
            boundary: boundary,
            chunkBottomY: trayTop
        ) else {
            logger.error("Could not rebuild the tray; keeping the one already placed")
            return
        }

        lowestLoadedY = candidate
        base?.removeFromParent()
        entity.name = Self.baseName
        entity.scale = SIMD3<Float>(repeating: 1 / max(geographicScale, .ulpOfOne))
        addChild(entity)
        base = entity
    }

    /// Rebuilds the wall closing the model's cut edge.
    ///
    /// The wall is assembled from the silhouette segments the clipper reported, gathered from the
    /// tiles that are *currently visible* rather than everything loaded. That matters during
    /// refinement: a coarse ancestor and the detail replacing it both carry cut edges along the same
    /// stretch of outline, at different heights, and walling both would leave the coarse one's
    /// standing proud of the model it no longer represents.
    ///
    /// It stops at the same level the tray's top sits at, so the two meet rather than leaving the
    /// gap this exists to close.
    private func updateCutWall() {
        guard style.clipsToBoundary, style.wall != .none, let prism = clipPrism else { return }
        guard let floorY = lowestVisibleY() else { return }

        var edges: [Tiles3DCutEdge] = []
        for child in children where child.isEnabled && !Self.derivedNames.contains(child.name) {
            guard let component = child.components[Tiles3DCutEdgeComponent.self] else { continue }
            edges.append(contentsOf: component.edges)
        }
        guard !edges.isEmpty else { return }

        // Rebuilding is a full mesh compile, and refinement asks several times a second, so the
        // cheap signature is what keeps this off the hot path once streaming settles. The edge
        // count stands in for the visible set: any tile appearing or being superseded moves it.
        if let placed = placedWall,
           placed.edgeCount == edges.count,
           abs(placed.floorY - floorY) < datumRebuildThreshold {
            return
        }

        // Built before the old one is taken away, and nothing committed until it succeeds — the
        // other order loses the wall outright on a failed build and then never tries again, because
        // the signature has already moved.
        let rebuilt: ModelEntity?
        do {
            rebuilt = try Tiles3DCutWall.generate(
                edges: edges,
                floorY: floorY,
                prism: prism,
                style: style.wall
            )
        } catch {
            logger.error("Could not rebuild the cut wall; keeping the one already placed")
            return
        }
        guard let rebuilt else { return }

        placedWall = (edges.count, floorY)
        cutWall?.removeFromParent()
        rebuilt.name = Self.cutWallName
        addChild(rebuilt)
        cutWall = rebuilt
    }

    /// Names of children this entity derives from the others, and so must not measure.
    private static let derivedNames: Set<String> = [baseName, cutWallName]
    /// Name used to keep the tray out of its own measurement.
    private static let baseName = "Tiles3DBase"
    /// Name used to keep the cut wall out of its own measurement.
    private static let cutWallName = "Tiles3DCutWall"

    @MainActor
    required init() {
        fatalError("Use init(provider:center:radiusMeters:) instead")
    }

    /// Updates the level-of-detail based on camera position.
    /// Call each frame on iOS/macOS with camera info, or on visionOS with head position.
    ///
    /// - Returns: How far the update got. One call is deliberately bounded, so a dense view needs
    ///   several; `requestLODUpdate` handles that for callers driving this from a view.
    @discardableResult
    public func updateLOD(
        cameraPosition: SIMD3<Float>,
        screenHeight: Float,
        fov: Float
    ) async -> Tiles3DLODManager.Refinement {
        await lodManager.update(
            parentEntity: self,
            cameraPosition: cameraPosition,
            screenHeight: screenHeight,
            fov: fov
        )
    }

    /// Requests a throttled LOD update. Safe to call every frame — internally
    /// skips the update if one is already in flight or if too little time has elapsed.
    ///
    /// `cameraPosition` should be in world space; it is automatically converted
    /// to the entity's local coordinate space using the geographic scale.
    ///
    /// The update keeps running until the model stops improving, rather than doing one bounded
    /// round and waiting to be asked again. It has to: this is called from a SwiftUI view update,
    /// which SwiftUI only re-runs when something changes, so a camera that stops moving with tiles
    /// outstanding would never ask again. Refinement would freeze part-way — and part-way is not a
    /// gap but a coarse ancestor still standing in for its children, so it reads as a blurred slab
    /// with a hard edge at the ancestor's bounds rather than as anything missing.
    public func requestLODUpdate(cameraPosition: SIMD3<Float>, screenHeight: Float, fov: Float) {
        // Level of detail is chosen in this entity's own space, where tiles are still in real
        // meters, so the camera has to come the other way. Asking RealityKit rather than dividing
        // by `geographicScale` picks up everything between here and the scene root: the entity's
        // own scale, the vertical anchoring below, and the fit-to-view scale the platform views
        // apply to the diorama. Dividing by the scale alone silently assumes those are identity.
        latestViewpoint = Viewpoint(
            cameraPosition: convert(position: cameraPosition, from: nil),
            screenHeight: screenHeight,
            fov: fov
        )

        guard !isLODUpdating else { return }
        if let last = lastLODUpdateTime, Date().timeIntervalSince(last) < Self.lodUpdateInterval {
            return
        }
        isLODUpdating = true

        Task { @MainActor [weak self] in
            defer { self?.isLODUpdating = false }

            for _ in 0..<Self.maxRefinementRounds {
                guard let self, let viewpoint = self.latestViewpoint else { return }
                self.lastLODUpdateTime = Date()

                let refinement = await self.updateLOD(
                    cameraPosition: viewpoint.cameraPosition,
                    screenHeight: viewpoint.screenHeight,
                    fov: viewpoint.fov
                )
                self.anchorGround()
                self.updateBase()
                self.updateCutWall()

                // `stalled` means the round brought nothing new, so repeating it would issue the
                // same requests again. That waits to be asked — a camera move changes the
                // traversal and can unstick it.
                guard refinement == .incomplete else { return }

                try? await Task.sleep(for: Self.refinementInterval)
            }
        }
    }
}
