import Foundation
import RealityKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Generates a flat water plane entity for filling sea-level areas in the diorama.
public enum WaterPlaneEntity {
    /// Creates a semi-transparent water disc at the given Y height.
    ///
    /// - Parameters:
    ///   - shape: The diorama shape (circular or rectangular).
    ///   - physicalDiameter: Physical diameter of the diorama in meters.
    ///   - waterY: Y position of the water surface in diorama space.
    /// - Returns: A `ModelEntity` representing the water surface.
    @MainActor
    public static func generate(
        shape: DioramaShape,
        physicalDiameter: Float,
        waterY: Float
    ) -> Entity {
        let mesh: MeshResource
        switch shape {
        case .circular:
            mesh = .generateCylinder(height: 0.001, radius: physicalDiameter / 2.0)
        case .rectangular(let width, let depth):
            mesh = .generateBox(width: width, height: 0.001, depth: depth)
        }

        var material = SimpleMaterial()
        #if canImport(UIKit)
        material.color.tint = UIColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 0.7)
        #elseif canImport(AppKit)
        material.color.tint = NSColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 0.7)
        #endif
        material.roughness = .float(0.3)
        material.metallic = .float(0.1)

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "WaterPlane"
        entity.position.y = waterY
        return entity
    }
}
