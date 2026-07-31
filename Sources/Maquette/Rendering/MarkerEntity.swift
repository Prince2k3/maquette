import Foundation
import RealityKit
import SwiftUI

/// A 3D pin entity representing a map marker on the diorama.
///
/// Composed of a sphere head and a thin cylinder stem, sized proportionally
/// to the diorama's physical diameter.
@MainActor
public class MarkerEntity: Entity {

    /// Creates a marker entity with the given appearance.
    ///
    /// - Parameters:
    ///   - tint: The color of the marker.
    ///   - physicalDiameter: The diorama's physical diameter, used to scale the marker proportionally.
    public init(tint: Color, physicalDiameter: Float) {
        super.init()
        self.name = "Marker"

        let markerScale = physicalDiameter * 0.015

        // Stem: thin cylinder
        let stemRadius = markerScale * 0.06
        let stemHeight = markerScale * 2.0
        let stemMesh = MeshResource.generateCylinder(height: stemHeight, radius: stemRadius)
        let stemMaterial = DioramaMaterials.unlitMaterial(color: tint)
        let stemEntity = ModelEntity(mesh: stemMesh, materials: [stemMaterial])
        stemEntity.name = "MarkerStem"
        stemEntity.position = SIMD3<Float>(0, stemHeight / 2, 0)
        addChild(stemEntity)

        // Head: sphere
        let headRadius = markerScale * 0.3
        let headMesh = MeshResource.generateSphere(radius: headRadius)
        let headMaterial = DioramaMaterials.unlitMaterial(color: tint)
        let headEntity = ModelEntity(mesh: headMesh, materials: [headMaterial])
        headEntity.name = "MarkerHead"
        headEntity.position = SIMD3<Float>(0, stemHeight + headRadius, 0)
        addChild(headEntity)
    }

    @MainActor
    required init() {
        super.init()
    }
}
