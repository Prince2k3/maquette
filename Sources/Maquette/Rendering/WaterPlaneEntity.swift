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
    /// Creates a semi-transparent water surface at the given Y height, cut to the chunk's outline.
    ///
    /// - Parameters:
    ///   - boundary: The chunk's outline, so the water stops exactly where the terrain does.
    ///   - waterY: Y position of the water surface in diorama space.
    /// - Returns: An entity representing the water surface, or `nil` if the surface could not
    ///   be generated.
    @MainActor
    public static func generate(
        boundary: DioramaBoundary,
        waterY: Float
    ) -> Entity? {
        // A zero-thickness prism gives a flat face that follows any boundary shape.
        guard let mesh = try? DioramaBase.prismMesh(
            outline: boundary.vertices,
            topY: 0,
            bottomY: -0.0005
        ) else {
            return nil
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
