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
    /// Where the water surface sits, given the chunk's baseline and elevation scale.
    ///
    /// Sea level is an elevation like any other, so it rides the elevation scale down — plus a lift
    /// that keeps it off the ground beneath it.
    ///
    /// **That lift is not a fudge for a rounding error; it is what stops the two surfaces being the
    /// same plane.** Terrarium carries no bathymetry over great stretches of ocean and reports the
    /// seabed as exactly 0, so a chunk cut from open water has every terrain vertex at sea level and
    /// the baseline sitting there too — which puts the terrain's top face and the water's top face
    /// at precisely Y = 0, coincident and coplanar. Two coplanar faces have no depth order for the
    /// renderer to find, so it resolves them per fragment and the chunk comes back striped. The same
    /// thing happens on a lake surface, and on any dataset that flattens water to the datum.
    ///
    /// It is measured against the chunk's own footprint rather than fixed in metres, because the
    /// separation has to stay meaningful against the depth range the camera frames — a diorama built
    /// at a tenth the size would otherwise get ten times the margin it needs, and one built ten times
    /// larger would get a tenth. And it is deliberately *not* scaled by ``elevationScale``: a ground
    /// zoom divides that scale, and a lift that went with it would shrink back into the fight it
    /// exists to prevent.
    ///
    /// - Parameters:
    ///   - boundary: The chunk's outline, which is also the footprint the lift is measured against.
    ///   - baselineElevation: The elevation diorama-space Y = 0 stands for, in metres.
    ///   - elevationScale: Diorama metres per metre of real elevation.
    public static func surfaceY(
        boundary: DioramaBoundary,
        baselineElevation: Float,
        elevationScale: Float
    ) -> Float {
        let footprint = max(boundary.extent.x, boundary.extent.y)
        return (0 - baselineElevation) * elevationScale + footprint * surfaceLift
    }

    /// How far the water floats above the ground it covers, as a share of the chunk's footprint.
    ///
    /// Small enough to be well under a pixel on any chunk anyone frames — an 0.8 m diorama gets
    /// 0.4 mm — and large enough that no depth buffer has to choose between the two surfaces.
    private static let surfaceLift: Float = 5e-4

    /// Creates a semi-transparent water surface at sea level, cut to the chunk's outline.
    ///
    /// - Parameters:
    ///   - boundary: The chunk's outline, so the water stops exactly where the terrain does.
    ///   - baselineElevation: The elevation diorama-space Y = 0 stands for, in metres.
    ///   - elevationScale: Diorama metres per metre of real elevation.
    /// - Returns: An entity representing the water surface, or `nil` if the surface could not
    ///   be generated.
    @MainActor
    public static func generate(
        boundary: DioramaBoundary,
        baselineElevation: Float,
        elevationScale: Float
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
        entity.position.y = surfaceY(
            boundary: boundary,
            baselineElevation: baselineElevation,
            elevationScale: elevationScale
        )
        return entity
    }
}
