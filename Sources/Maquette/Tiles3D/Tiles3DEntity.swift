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

    /// The outline the model is cut to, and what it rests on.
    private let style: Tiles3DStyle
    private let boundary: DioramaBoundary
    /// The tray beneath the model, if the style asks for one.
    public private(set) var base: Entity?
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
        super.init()
        self.name = "Tiles3D"
        self.scale = SIMD3<Float>(repeating: geographicScale)

        try await lodManager.start()
        logger.info("3D Tiles entity initialized (scale=\(self.geographicScale), clipped=\(prism != nil)): \(provider.attribution)")
    }

    /// Repositions the tray to sit just beneath the model that is actually on screen.
    ///
    /// Two things make the naive measurement wrong. Measuring every child includes the tray
    /// itself, so it chases its own underside downward by a thickness on every update. And
    /// measuring tiles that are loaded but hidden includes superseded coarse ancestors, which
    /// span far more ground — and therefore reach far lower — than the detail that replaced them.
    /// Only the visible tiles describe where the model's underside really is.
    private func updateBase() {
        guard case .tray(let color, let thickness, let inset) = style.base else { return }

        var candidate = Float.greatestFiniteMagnitude
        for child in children where child.isEnabled && child.name != Self.baseName {
            let bounds = child.visualBounds(relativeTo: self)
            guard bounds.min.y.isFinite else { continue }
            candidate = min(candidate, bounds.min.y)
        }

        guard candidate < .greatestFiniteMagnitude else { return }

        // Tracked in both directions, since refinement can raise the underside as well as lower
        // it, but only rebuilt on a meaningful move so the tray does not jitter every update.
        let threshold = max(thickness, .ulpOfOne) / max(geographicScale, .ulpOfOne) * 0.25
        if let placed = lowestLoadedY, abs(candidate - placed) < threshold { return }
        lowestLoadedY = candidate

        base?.removeFromParent()
        // Geometry here is pre-scale, but `DioramaBase` works in diorama meters, so the tray is
        // built in diorama space and divided back into this entity's space.
        let trayTop = candidate * geographicScale
        guard let entity = try? DioramaBase.generate(
            style: .plinth(color: color, height: thickness, inset: inset),
            boundary: boundary,
            chunkBottomY: trayTop
        ) else { return }

        entity.name = Self.baseName
        entity.scale = SIMD3<Float>(repeating: 1 / max(geographicScale, .ulpOfOne))
        addChild(entity)
        base = entity
    }

    /// Name used to keep the tray out of its own measurement.
    private static let baseName = "Tiles3DBase"

    @MainActor
    required init() {
        fatalError("Use init(provider:center:radiusMeters:) instead")
    }

    /// Updates the level-of-detail based on camera position.
    /// Call each frame on iOS/macOS with camera info, or on visionOS with head position.
    public func updateLOD(cameraPosition: SIMD3<Float>, screenHeight: Float, fov: Float) async {
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
    public func requestLODUpdate(cameraPosition: SIMD3<Float>, screenHeight: Float, fov: Float) {
        guard !isLODUpdating else { return }
        if let last = lastLODUpdateTime, Date().timeIntervalSince(last) < Self.lodUpdateInterval {
            return
        }
        isLODUpdating = true
        lastLODUpdateTime = Date()

        // Convert world-space camera position to entity-local coordinates.
        // The entity's scale converts real-meter positions to physical-diorama positions,
        // so dividing world position by scale gives us the camera position in real meters.
        let localCamera = cameraPosition / geographicScale

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.updateLOD(
                cameraPosition: localCamera,
                screenHeight: screenHeight,
                fov: fov
            )
            self.updateBase()
            self.isLODUpdating = false
        }
    }
}
