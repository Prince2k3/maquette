import Foundation
import RealityKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Entity that displays a terrain chunk: the imagery-textured surface on top, the cut walls
/// showing the earth beneath it, and the closing face underneath.
@MainActor
public class TerrainEntity: Entity {
    /// The terrain surface model.
    public private(set) var surface: ModelEntity?
    /// The cut wall model, if the chunk has walls.
    public private(set) var walls: ModelEntity?
    /// The bottom face model, if the chunk is closed.
    public private(set) var bottom: ModelEntity?
    /// How far the chunk extends below diorama Y = 0, in diorama meters.
    public private(set) var baseDepth: Float = 0
    /// Highest point of the terrain surface in diorama-space Y.
    public private(set) var maxSurfaceY: Float = 0

    /// Creates a terrain chunk entity from generated mesh parts.
    ///
    /// - Parameters:
    ///   - parts: The generated chunk meshes.
    ///   - surfaceMaterial: Material for the terrain surface, typically satellite imagery.
    ///   - wallMaterial: Material for the cut walls. Pass `nil` to omit the walls.
    ///   - bottomMaterial: Material for the bottom face. Pass `nil` to omit the bottom.
    public init(
        parts: TerrainSolidParts,
        surfaceMaterial: RealityKit.Material,
        wallMaterial: RealityKit.Material?,
        bottomMaterial: RealityKit.Material?
    ) {
        super.init()
        self.name = "TerrainChunk"
        self.baseDepth = parts.baseDepth
        self.maxSurfaceY = parts.maxSurfaceY

        let surfaceModel = ModelEntity(mesh: parts.top, materials: [surfaceMaterial])
        surfaceModel.name = "TerrainSurface"
        addChild(surfaceModel)
        self.surface = surfaceModel

        if let wallMesh = parts.walls, let wallMaterial {
            let wallModel = ModelEntity(mesh: wallMesh, materials: [wallMaterial])
            wallModel.name = "TerrainWalls"
            addChild(wallModel)
            self.walls = wallModel
        }

        if let bottomMesh = parts.bottom, let bottomMaterial {
            let bottomModel = ModelEntity(mesh: bottomMesh, materials: [bottomMaterial])
            bottomModel.name = "TerrainBottom"
            addChild(bottomModel)
            self.bottom = bottomModel
        }
    }

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
        self.surface = modelEntity
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
