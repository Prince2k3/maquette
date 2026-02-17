import Foundation
import RealityKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Entity that displays terrain mesh with satellite imagery texture.
@MainActor
public class TerrainEntity: Entity {
    /// Creates a terrain entity from a mesh and a pre-built material.
    ///
    /// - Parameters:
    ///   - mesh: The terrain mesh resource.
    ///   - material: The RealityKit material to apply to the terrain surface.
    public init(mesh: MeshResource, material: RealityKit.Material) {
        super.init()
        self.name = "Terrain"

        let modelEntity = ModelEntity(mesh: mesh, materials: [material])
        modelEntity.name = "TerrainModel"
        addChild(modelEntity)
    }

    /// Creates a terrain entity from a mesh and optional satellite image data.
    ///
    /// - Parameters:
    ///   - mesh: The terrain mesh resource.
    ///   - satelliteImageData: Raw PNG/JPEG satellite image data for texturing. If `nil`, a default material is used.
    ///   - physicalDiameter: Physical diameter of the diorama in meters.
    public init(mesh: MeshResource, satelliteImageData: Data?, physicalDiameter: Float) {
        super.init()
        self.name = "Terrain"

        let material: RealityKit.Material
        if let imageData = satelliteImageData,
           let textureMaterial = try? DioramaMaterials.satelliteTextureMaterial(from: imageData) {
            material = textureMaterial
        } else {
            material = Self.fallbackMaterial()
        }

        let modelEntity = ModelEntity(mesh: mesh, materials: [material])
        modelEntity.name = "TerrainModel"
        addChild(modelEntity)
    }

    static func fallbackMaterial() -> SimpleMaterial {
        var fallback = SimpleMaterial()
        #if canImport(UIKit)
        fallback.color.tint = UIColor(white: 0.6, alpha: 1.0)
        #elseif canImport(AppKit)
        fallback.color.tint = NSColor(white: 0.6, alpha: 1.0)
        #endif
        fallback.roughness = .float(0.7)
        return fallback
    }

    @MainActor
    required init() {
        super.init()
    }
}
