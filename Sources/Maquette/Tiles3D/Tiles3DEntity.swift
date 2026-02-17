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

    /// Creates a 3D Tiles entity from a provider.
    /// - Parameters:
    ///   - provider: The 3D Tiles data source.
    ///   - center: Geographic center of the diorama.
    ///   - radiusMeters: Radius of the diorama in meters.
    public init(
        provider: any Tiles3DProvider,
        center: CLLocationCoordinate2D,
        radiusMeters: Double
    ) async throws {
        let ecefConverter = ECEFConverter(origin: center)
        self.lodManager = Tiles3DLODManager(
            provider: provider,
            ecefConverter: ecefConverter,
            radiusMeters: radiusMeters
        )
        super.init()
        self.name = "Tiles3D"

        try await lodManager.start()
        logger.info("3D Tiles entity initialized with provider: \(provider.attribution)")
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
}
