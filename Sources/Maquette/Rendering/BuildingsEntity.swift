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
/// `dioramaPoint(P) - panOffset`. Buildings therefore ride the pan on this container's transform,
/// which is exact horizontally and costs nothing.
///
/// The transform is only half of it, and deliberately so. It puts every block over its own ground,
/// but it cannot decide *which* blocks the outline covers now — slide the mesh far enough and it
/// hangs past the rim on one side with nothing behind it on the other. `DioramaStore` answers that
/// half by selecting again off the main actor and calling ``show(_:)``, so the two arrive at
/// different rates: the transform every frame, a fresh selection every few milliseconds. That is why
/// a selection is made in ground space rather than in screen-fixed chunk space — a mesh drawn for a
/// slightly older offset is still in exactly the right place, so the lag shows up as the rim being a
/// moment late and never as the buildings jumping.
///
/// The vertices themselves are uploaded once, by ``install(_:)``. A pan changes which blocks are
/// indexed and never where any of them is, so a step rewrites the index buffer and leaves several
/// megabytes of vertices alone.
///
/// What still does not happen is a *refetch*: the footprints are the ones the initial fetch covered,
/// which is the outline plus the pan margin. Pan past that ring and the leading edge runs out.
@MainActor
final class BuildingsEntity: Entity {
    private static let logger = Logger(maquette: "BuildingsEntity")

    private let model = ModelEntity()
    private let material: any RealityKit.Material
    private let followsPan: Bool
    private var buffer: Tiles3DMeshBuffer?

    /// How many buildings the current mesh draws.
    private(set) var buildingCount = 0

    /// Whether the caller wants the blocks drawn at all.
    ///
    /// Held apart from `isEnabled`, which answers a different question — whether there is anything to
    /// draw. Both end up as the same flag on the entity, so a caller that reached for `isEnabled`
    /// directly would have its choice overwritten by the next ``show(_:)``, which is every few
    /// milliseconds during a pan.
    var isVisible = true {
        didSet {
            guard isVisible != oldValue else { return }
            applyVisibility()
        }
    }

    /// Whether ``show(_:)`` last put geometry in the index buffer.
    private var hasGeometry = false

    init(style: BuildingStyle) {
        self.material = DioramaMaterials.buildingMaterial(
            color: style.color,
            opacity: style.opacity
        )
        self.followsPan = style.followsPan
        super.init()
        addChild(model)
        isVisible = style.isVisible
        applyVisibility()
    }

    @MainActor required init() {
        fatalError("init() is unavailable; use init(style:)")
    }

    /// Uploads every block the fetch covered. Nothing here is drawn until ``show(_:)`` picks a subset.
    ///
    /// Sized to the whole arena rather than to what is currently visible, so a pan can select any
    /// subset — up to all of it — without the buffer ever having to grow. That is what lets a step be
    /// an index rewrite: a regrow would replace the `MeshResource` and lose the vertices with it.
    func install(_ blocks: BuildingExtruder.Blocks) {
        buffer = nil
        model.model = nil
        hasGeometry = false
        applyVisibility()
        buildingCount = 0
        guard !blocks.vertices.isEmpty, !blocks.indices.isEmpty else { return }

        do {
            // Same reason the hologram and the 3D Tiles rim use this: `MeshResource.generate` runs a
            // full asset compile, measured at 12 ms against 0.14 ms for a buffer write.
            let buffer = try Tiles3DMeshBuffer(
                vertexCapacity: blocks.vertices.count,
                indexCapacity: blocks.indices.count
            )
            buffer.writeVertices(blocks.vertices)
            self.buffer = buffer
            model.model = ModelComponent(mesh: buffer.resource, materials: [material])
        } catch {
            Self.logger.error(
                "Could not build the buildings mesh: \(error.localizedDescription)"
            )
        }
    }

    /// Draws the blocks the outline covers now.
    func show(_ selection: BuildingExtruder.Selection) {
        buildingCount = selection.kept
        guard let buffer else { return }
        hasGeometry = buffer.writeIndices(selection.indices, bounds: selection.bounds) != .empty
        applyVisibility()
    }

    private func applyVisibility() {
        isEnabled = hasGeometry && isVisible
    }

    /// Slides the buildings with the ground.
    ///
    /// The chunk's outline does not move, so ground panned by `offset` draws at `-offset`.
    func setPanOffset(_ offset: SIMD2<Float>) {
        guard followsPan else { return }
        position = SIMD3(-offset.x, 0, -offset.y)
    }
}
