import Foundation
import RealityKit
import simd

/// A vertex in the layout the tiles are drawn with.
///
/// Written out as scalars rather than `SIMD3<Float>` so the stride is 32 bytes instead of 48: a
/// `SIMD3` is 16-byte aligned, which would pad every position and normal by a third.
///
/// This is also the layout the clip produces, so a cut tile reaches the GPU as one bulk copy. Going
/// through `MeshDescriptor` meant writing every vertex three times over — into the descriptor's
/// separate position, normal and texture-coordinate arrays, back out of them, then into this — for
/// geometry that is thrown away and rebuilt on the next pan step.
struct Tiles3DVertex {
    var px: Float, py: Float, pz: Float
    var nx: Float, ny: Float, nz: Float
    var u: Float, v: Float

    init(position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>) {
        px = position.x
        py = position.y
        pz = position.z
        nx = normal.x
        ny = normal.y
        nz = normal.z
        u = uv.x
        v = uv.y
    }

    var position: SIMD3<Float> { SIMD3(px, py, pz) }
    var normal: SIMD3<Float> { SIMD3(nx, ny, nz) }
    var uv: SIMD2<Float> { SIMD2(u, v) }
}

/// Geometry that is rebuilt as the outline moves, held as a buffer that can be rewritten in place.
///
/// `MeshResource.generate` compiles an asset every time it is called, which is the wrong cost to pay
/// for geometry that changes on every pan step — the raster path measured 12 ms against 0.14 ms for
/// writing a vertex buffer directly, and a pan calls it once per rim tile plus once for the cut
/// wall. A `LowLevelMesh` is the same escape hatch: RealityKit keeps rendering from the buffer, so
/// rewriting its contents replaces the compile with a copy.
///
/// The capacity is the wrinkle. A `LowLevelMesh` fixes its capacity when it is created, but a clip
/// against a moved outline yields a different number of vertices every time. So the buffer is grown
/// with headroom and only recreated when a cut genuinely needs more room than it has — after a few
/// steps the rim tiles have all reached a size that fits, and the recreations stop.
@MainActor
final class Tiles3DMeshBuffer {
    /// Fraction of extra capacity taken when the buffer has to grow, so a cut that creeps up by a
    /// few vertices a step does not recreate the mesh every step.
    private static let headroom = 1.25

    private var mesh: LowLevelMesh
    private(set) var resource: MeshResource
    private var vertexCapacity: Int
    private var indexCapacity: Int

    init(vertexCapacity: Int, indexCapacity: Int) throws {
        let (mesh, resource) = try Self.make(vertexCapacity: vertexCapacity, indexCapacity: indexCapacity)
        self.mesh = mesh
        self.resource = resource
        self.vertexCapacity = vertexCapacity
        self.indexCapacity = indexCapacity
    }

    private static func descriptor(vertexCapacity: Int, indexCapacity: Int) -> LowLevelMesh.Descriptor {
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: 0),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<Float>.stride * 3),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<Float>.stride * 6),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<Tiles3DVertex>.stride)]
        descriptor.indexType = .uint32
        descriptor.vertexCapacity = vertexCapacity
        descriptor.indexCapacity = indexCapacity
        return descriptor
    }

    private static func make(
        vertexCapacity: Int,
        indexCapacity: Int
    ) throws -> (LowLevelMesh, MeshResource) {
        let mesh = try LowLevelMesh(
            descriptor: descriptor(vertexCapacity: vertexCapacity, indexCapacity: indexCapacity)
        )
        return (mesh, try MeshResource(from: mesh))
    }

    /// What a write left behind.
    enum Outcome {
        /// Nothing drawable — the caller should clear the entity's model.
        case empty
        /// Written into the buffer the entity is already drawing from; nothing else to do.
        case rewritten
        /// The buffer had to grow, so `resource` is a new one the entity has to be given.
        case regrown
    }

    /// Rewrites the buffer from a freshly clipped tile.
    ///
    /// Both copies are bulk. The clip produced this exact layout, so nothing here walks a vertex at
    /// a time, and the bounds came out of the clip too rather than from a second pass over the
    /// positions.
    @discardableResult
    func write(vertices: [Tiles3DVertex], indices: [UInt32], bounds: BoundingBox) throws -> Outcome {
        guard !vertices.isEmpty, !indices.isEmpty else { return .empty }

        var recreated = false
        if vertices.count > vertexCapacity || indices.count > indexCapacity {
            let vertexRoom = max(Int(Double(vertices.count) * Self.headroom), vertexCapacity)
            let indexRoom = max(Int(Double(indices.count) * Self.headroom), indexCapacity)
            (mesh, resource) = try Self.make(vertexCapacity: vertexRoom, indexCapacity: indexRoom)
            vertexCapacity = vertexRoom
            indexCapacity = indexRoom
            recreated = true
        }

        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            _ = raw.bindMemory(to: Tiles3DVertex.self).update(fromContentsOf: vertices)
        }

        mesh.withUnsafeMutableIndices { raw in
            _ = raw.bindMemory(to: UInt32.self).update(fromContentsOf: indices)
        }

        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexCount: indices.count,
                topology: .triangle,
                materialIndex: 0,
                bounds: bounds
            )
        ])
        return recreated ? .regrown : .rewritten
    }
}
