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
    /// How far the terrain has slid beneath the chunk's outline, in diorama meters.
    public private(set) var panOffset: SIMD2<Float> = .zero

    /// Retained geometry, and the terrain it samples when the chunk can pan.
    private var geometry: TerrainSolidGenerator.Geometry?
    private var heightField: TerrainHeightField?
    /// Directly-writable meshes, used in place of regenerating resources on every pan.
    private var surfaceMesh: ChunkSurfaceMesh?
    private var wallMesh: ChunkSurfaceMesh?

    /// Creates a terrain chunk entity from generated mesh parts.
    ///
    /// - Parameters:
    ///   - parts: The generated chunk meshes.
    ///   - surfaceMaterial: Material for the terrain surface, typically satellite imagery.
    ///   - wallMaterial: Material for the cut walls. Pass `nil` to omit the walls.
    ///   - bottomMaterial: Material for the bottom face. Pass `nil` to omit the bottom.
    ///   - pannableTerrain: The terrain to re-sample when the chunk pans. Pass `nil` for a fixed
    ///     chunk, which skips the directly-writable meshes a pan needs.
    public init(
        parts: TerrainSolidParts,
        surfaceMaterial: RealityKit.Material,
        wallMaterial: RealityKit.Material?,
        bottomMaterial: RealityKit.Material?,
        pannableTerrain: TerrainHeightField? = nil
    ) {
        super.init()
        self.name = "TerrainChunk"
        self.baseDepth = parts.baseDepth
        self.maxSurfaceY = parts.maxSurfaceY

        // Kept whether or not the chunk pans: an effect reads the surface triangles to trace its
        // contours from, and it can be switched on at any point after the chunk was built.
        self.geometry = parts.geometry

        // A pannable chunk is additionally backed by directly-writable meshes so a pan is a buffer
        // write rather than a fresh resource build.
        if let pannableTerrain {
            self.heightField = pannableTerrain
            self.surfaceMesh = try? ChunkSurfaceMesh(buffers: parts.geometry.top, name: "terrainTop")
            if !parts.geometry.walls.indices.isEmpty {
                self.wallMesh = try? ChunkSurfaceMesh(buffers: parts.geometry.walls, name: "terrainWalls")
            }
        }

        let surfaceModel = ModelEntity(
            mesh: surfaceMesh?.resource ?? parts.top,
            materials: [surfaceMaterial]
        )
        surfaceModel.name = "TerrainSurface"
        addChild(surfaceModel)
        self.surface = surfaceModel

        if let wallResource = wallMesh?.resource ?? parts.walls, let wallMaterial {
            let wallModel = ModelEntity(mesh: wallResource, materials: [wallMaterial])
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

    /// Whether this chunk retains what it needs to pan.
    public var canPan: Bool { geometry != nil && heightField != nil }

    /// The chunk's top-surface triangles as they currently stand.
    ///
    /// Already clipped to the outline, and already re-sampled by whatever pan is in effect, which is
    /// what lets an effect trace lines that stop exactly on the cut edge without repeating the
    /// boundary clip for itself.
    var surfaceBuffers: TerrainSolidGenerator.Buffers? { geometry?.top }

    /// Slides the terrain beneath the chunk's fixed outline.
    ///
    /// Only heights, shading, and imagery change — the chunk keeps its shape and position, so the
    /// clipped topology built at generation is reused rather than rebuilt.
    ///
    /// - Parameter offset: The new offset in diorama meters. Callers are expected to have clamped
    ///   it to the fetched region; sampling past the edge clamps to the terrain's border.
    public func setPanOffset(_ offset: SIMD2<Float>) {
        guard var geometry, let heightField, offset != panOffset else { return }

        TerrainSolidGenerator.resample(&geometry, heightField: heightField, panOffset: offset)

        surfaceMesh?.update(from: geometry.top)
        wallMesh?.update(from: geometry.walls)

        self.geometry = geometry
        self.panOffset = offset
    }

    /// Swaps in freshly-rolled ground beneath the chunk.
    ///
    /// Elevation and imagery are one mapping, not two, so they have to land together — handing the
    /// height field over without its imagery would texture the new ground with the old picture for
    /// as long as it took the material to follow.
    ///
    /// - Parameters:
    ///   - heightField: The new surface. It must share the anchor the chunk was built with, or the
    ///     terrain jumps.
    ///   - surfaceMaterial: Imagery composited over the same tiles, or `nil` to keep the current one.
    public func setTerrain(_ heightField: TerrainHeightField, surfaceMaterial: RealityKit.Material?) {
        guard var geometry, self.heightField != nil else { return }

        self.heightField = heightField
        if let surfaceMaterial {
            surface?.model?.materials = [surfaceMaterial]
        }

        TerrainSolidGenerator.resample(&geometry, heightField: heightField, panOffset: panOffset)
        surfaceMesh?.update(from: geometry.top)
        wallMesh?.update(from: geometry.walls)
        self.geometry = geometry
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
