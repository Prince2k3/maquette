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

    /// Creates a 3D Tiles entity from a provider.
    /// - Parameters:
    ///   - provider: The 3D Tiles data source.
    ///   - center: Geographic center of the diorama.
    ///   - radiusMeters: Radius of the diorama in meters.
    ///   - physicalDiameter: The diorama's physical diameter in meters.
    public init(
        provider: any Tiles3DProvider,
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        physicalDiameter: Float
    ) async throws {
        let ecefConverter = ECEFConverter(origin: center)
        self.lodManager = Tiles3DLODManager(
            provider: provider,
            ecefConverter: ecefConverter,
            center: center,
            radiusMeters: radiusMeters
        )
        self.geographicScale = physicalDiameter / Float(radiusMeters * 2.0)
        super.init()
        self.name = "Tiles3D"
        self.scale = SIMD3<Float>(repeating: geographicScale)

        try await lodManager.start()
        logger.info("3D Tiles entity initialized (scale=\(self.geographicScale)): \(provider.attribution)")
    }

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
            self.isLODUpdating = false
        }
    }
}
