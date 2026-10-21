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
class TerrainEntity: Entity {
    /// The terrain surface model.
    public private(set) var surface: ModelEntity?
    /// The cut wall model, if the chunk has walls.
    public private(set) var walls: ModelEntity?
    /// The bottom face model, if the chunk is closed.
    public private(set) var bottom: ModelEntity?
    /// How far the chunk extends below diorama Y = 0, in diorama meters.
    ///
    /// Fixed at generation, and it stays fixed through a pan and through a ground zoom alike: the
    /// earth mass is what the strata wall is made of, and a wall that changed height in answer to a
    /// pinch would make the chunk a different object at every zoom.
    public private(set) var baseDepth: Float = 0
    /// Highest point of the terrain surface in diorama-space Y.
    public private(set) var maxSurfaceY: Float = 0
    /// How far the terrain has slid beneath the chunk's outline, in diorama meters.
    public private(set) var panOffset: SIMD2<Float> = .zero
    /// The ground zoom the chunk is currently drawn at.
    public private(set) var groundScale: Float = 1

    /// Retained geometry, and the terrain it samples when the chunk can pan.
    private var geometry: TerrainSolidGenerator.Geometry?
    private(set) var surfaceRevision = 0
    private var heightField: TerrainHeightField?
    private(set) var isPanPresentationDeferred = false
    private(set) var presentedPanOffset: SIMD2<Float> = .zero
    private(set) var presentedSurfaceRevision = 0
    private var pendingSurfaceMaterial: (any RealityKit.Material)?
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
    /// During a deferred pan this is the CPU candidate; GPU buffers still match presentedPanOffset.
    /// Effects are refreshed by the store's presentation completion, after the candidate is installed.
    /// Already clipped to the outline, and already re-sampled by whatever pan is in effect, which is
    /// what lets an effect trace lines that stop exactly on the cut edge without repeating the
    /// boundary clip for itself.
    var surfaceBuffers: TerrainSolidGenerator.Buffers? { geometry?.top }

    /// The chunk's cut walls as they currently stand.
    ///
    /// Each quad's vertices run top, bottom, top, bottom, so the even ones are the rim — the same
    /// convention `TerrainSolidGenerator.resample` relies on. An effect that moves the top surface has
    /// to move these with it or the wall stands proud of the surface it is supposed to meet.
    var wallBuffers: TerrainSolidGenerator.Buffers? { geometry?.walls }
    var bottomBuffers: TerrainSolidGenerator.Buffers? { geometry?.bottom }

    /// The vertical span the wall texture's coordinates are normalized against.
    var wallHeight: Float { geometry?.resampling.wallHeight ?? 0 }

    /// The materials the chunk's own walls are drawn with, so an effect that replaces the wall
    /// geometry can keep its strata rather than repainting them flat.
    var wallMaterials: [any RealityKit.Material] { walls?.model?.materials ?? [] }

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

        isPanPresentationDeferred = (parent as? DioramaEntity)?.overlayRenderer.canDeferPanPresentation == true
        if !isPanPresentationDeferred {
            surfaceMesh?.update(from: geometry.top)
            wallMesh?.update(from: geometry.walls)
            presentedPanOffset = offset
        }

        self.geometry = geometry
        self.panOffset = offset
        surfaceRevision &+= 1
        if !isPanPresentationDeferred { presentedSurfaceRevision = surfaceRevision }
    }

    /// Publishes the CPU candidate only when its matching overlays are ready.
    func commitPanPresentation() {
        guard isPanPresentationDeferred, let geometry else { return }
        if let pendingSurfaceMaterial { surface?.model?.materials = [pendingSurfaceMaterial] }
        pendingSurfaceMaterial = nil
        surfaceMesh?.update(from: geometry.top)
        wallMesh?.update(from: geometry.walls)
        presentedPanOffset = panOffset
        presentedSurfaceRevision = surfaceRevision
        isPanPresentationDeferred = false
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
    ///   - newPanOffset: The offset the new surface should be sampled at, or `nil` to keep the
    ///     current one. A roll keeps it, because the mapping is unchanged and the offset still names
    ///     the ground it did before. A ground zoom does not: the mapping's scale has changed, and the
    ///     offset has to be divided by the same factor to hold the chunk over the same place. Passing
    ///     it here rather than calling ``setPanOffset(_:)`` afterwards is what keeps a zoom step to
    ///     one resample instead of two — and the first of those two would be against the old surface.
    ///   - groundScale: The ground zoom the new surface is read at, or `nil` to keep the current
    ///     one. A roll keeps it; a ground zoom sets it. Nothing about the chunk's own shape follows
    ///     from it — the earth mass stays where it was generated — so this is recorded rather than
    ///     acted on, and it is the terrain read through the new surface that changes.
    public func setTerrain(
        _ heightField: TerrainHeightField,
        surfaceMaterial: RealityKit.Material?,
        panOffset newPanOffset: SIMD2<Float>? = nil,
        groundScale newGroundScale: Float? = nil
    ) {
        guard var geometry, self.heightField != nil else { return }

        // A mapping change needs the same complete-frame handoff as a pan: retain the
        // displayed buffers until overlays have been rebuilt against this CPU candidate.
        isPanPresentationDeferred = (parent as? DioramaEntity)?.overlayRenderer.canDeferPanPresentation == true
        self.heightField = heightField
        if let newPanOffset {
            self.panOffset = newPanOffset
        }
        if let newGroundScale, newGroundScale > 0 {
            self.groundScale = newGroundScale
        }
        if isPanPresentationDeferred {
            if let surfaceMaterial { pendingSurfaceMaterial = surfaceMaterial }
        } else {
            // A zoom may supersede a staged roll while keeping its newly loaded grids.
            // Keep that roll's imagery too when the caller asks to retain the material.
            if let material = surfaceMaterial ?? pendingSurfaceMaterial { surface?.model?.materials = [material] }
            pendingSurfaceMaterial = nil
        }

        TerrainSolidGenerator.resample(&geometry, heightField: heightField, panOffset: panOffset)
        if !isPanPresentationDeferred {
            surfaceMesh?.update(from: geometry.top)
            wallMesh?.update(from: geometry.walls)
            presentedPanOffset = panOffset
        }
        self.geometry = geometry
        surfaceRevision &+= 1
        if !isPanPresentationDeferred { presentedSurfaceRevision = surfaceRevision }
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
    ///   - physicalSize: Physical diameter of the diorama in meters.
    public init(mesh: MeshResource, satelliteImageData: Data?, physicalSize: Float) {
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
