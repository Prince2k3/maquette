import Foundation
import RealityKit
import os
import simd

/// The extruded buildings standing on a terrain chunk, as one drawable.
///
/// Every footprint in the region goes into a single mesh rather than one entity apiece. A downtown
/// block is a few thousand buildings, and a few thousand `ModelEntity`s would cost a draw call each
/// for geometry that never moves relative to its neighbours.
///
/// ## Panning
///
/// The chunk's outline is fixed and the ground slides beneath it, so a geographic point P appears at
/// `dioramaPoint(P) - panOffset`. Buildings therefore ride the pan on the container's transform,
/// which is exact horizontally and costs nothing — no re-extrusion, no refetch.
///
/// What it does *not* do is re-decide which buildings are inside the outline, or re-seat them on
/// ground that has been re-sampled. So a pan slides the whole block of buildings as a unit: they
/// spill past the rim rather than being cut at it, and any that were dropped for crossing the
/// outline stay dropped. Both are prototype limits. Cutting at the rim needs the clip
/// ``BuildingExtruder`` deliberately does not do; keeping the set current needs a fetch tied to
/// ``TerrainRoller``.
@MainActor
final class BuildingsEntity: Entity {
    private static let logger = Logger(subsystem: "com.maquette", category: "Buildings")

    private let model = ModelEntity()
    private let material: any RealityKit.Material
    private let followsPan: Bool
    private var buffer: Tiles3DMeshBuffer?

    /// How many buildings the current mesh draws.
    private(set) var buildingCount = 0

    init(style: BuildingStyle) {
        self.material = DioramaMaterials.buildingMaterial(
            color: style.color,
            opacity: style.opacity
        )
        self.followsPan = style.followsPan
        super.init()
        addChild(model)
        isEnabled = false
    }

    @MainActor required init() {
        fatalError("init() is unavailable; use init(style:)")
    }

    /// Replaces the drawn geometry.
    func update(with mesh: IndexedMesh, buildingCount: Int) {
        self.buildingCount = buildingCount
        guard !mesh.isEmpty else {
            isEnabled = false
            return
        }

        do {
            // Same reason the hologram and the 3D Tiles rim use this: `MeshResource.generate` runs a
            // full asset compile, measured at 12 ms against 0.14 ms for a buffer write.
            let buffer = try self.buffer ?? Tiles3DMeshBuffer(
                vertexCapacity: mesh.vertices.count,
                indexCapacity: mesh.indices.count
            )
            let fresh = self.buffer == nil
            self.buffer = buffer

            let outcome = try buffer.write(
                vertices: mesh.vertices,
                indices: mesh.indices,
                bounds: mesh.bounds
            )
            switch outcome {
            case .empty:
                isEnabled = false
                return
            case .regrown:
                model.model = ModelComponent(mesh: buffer.resource, materials: [material])
            case .rewritten:
                if fresh || model.model == nil {
                    model.model = ModelComponent(mesh: buffer.resource, materials: [material])
                }
            }
            isEnabled = true
        } catch {
            Self.logger.error(
                "Could not build the buildings mesh: \(error.localizedDescription)"
            )
            isEnabled = false
        }
    }

    /// Slides the buildings with the ground.
    ///
    /// The chunk's outline does not move, so ground panned by `offset` draws at `-offset`.
    func setPanOffset(_ offset: SIMD2<Float>) {
        guard followsPan else { return }
        position = SIMD3(-offset.x, 0, -offset.y)
    }
}
