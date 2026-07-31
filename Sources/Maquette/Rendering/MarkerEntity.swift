import Foundation
import RealityKit
import SwiftUI

/// A 3D pin entity representing a map marker on the diorama.
///
/// Composed of a sphere head and a thin cylinder stem, sized proportionally
/// to the diorama's physical diameter.
@MainActor
class MarkerEntity: Entity {

    /// Creates a marker entity with the given appearance.
    ///
    /// - Parameters:
    ///   - tint: The color of the marker.
    ///   - physicalSize: The diorama's physical diameter, used to scale the marker proportionally.
    public init(tint: Color, physicalSize: Float) {
        super.init()
        self.name = "Marker"

        let markerScale = physicalSize * 0.015

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

        // A tap target. The collision sphere covers the whole pin rather than the head alone —
        // the head is a couple of millimetres across on a tabletop diorama, and a target that
        // small punishes exactly the gesture selection exists for.
        let hitRadius = stemHeight + headRadius * 2
        components.set(CollisionComponent(shapes: [
            .generateSphere(radius: hitRadius).offsetBy(translation: SIMD3<Float>(0, hitRadius / 2, 0))
        ]))
        components.set(InputTargetComponent())
    }

    /// Reflects selection: a selected pin stands half again as large.
    ///
    /// Scale rather than a colour change, because the tint is the caller's own vocabulary — two
    /// markers distinguished by colour must stay distinguishable while one of them is selected.
    public func setSelected(_ selected: Bool) {
        scale = SIMD3<Float>(repeating: selected ? 1.5 : 1.0)
    }

    @MainActor
    required init() {
        super.init()
    }
}
