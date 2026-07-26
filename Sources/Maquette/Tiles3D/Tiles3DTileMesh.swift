import Foundation
import RealityKit
import simd

/// One streamed tile's drawable geometry, held as a buffer that can be rewritten in place.
///
/// `MeshResource.generate` compiles an asset every time it is called, which is the wrong cost to pay
/// for geometry that changes on every pan step — the raster path measured 12 ms against 0.14 ms for
/// writing a vertex buffer directly, and this path calls it once per rim tile. A `LowLevelMesh` is
/// the same escape hatch: RealityKit keeps rendering from the buffer, so rewriting its contents
/// replaces the compile with a copy.
///
/// The capacity is the wrinkle. A `LowLevelMesh` fixes its capacity when it is created, but a clip
/// against a moved outline yields a different number of vertices every time. So the buffer is grown
/// with headroom and only recreated when a cut genuinely needs more room than it has — after a few
/// steps the rim tiles have all reached a size that fits, and the recreations stop.
@MainActor
final class Tiles3DTileMesh {
    /// A vertex in the layout the tiles are drawn with.
    ///
    /// Written out as scalars rather than `SIMD3<Float>` so the stride is 32 bytes instead of 48:
    /// a `SIMD3` is 16-byte aligned, which would pad every position and normal by a third.
    struct Vertex {
        var px: Float, py: Float, pz: Float
        var nx: Float, ny: Float, nz: Float
        var u: Float, v: Float
    }

    /// Fraction of extra capacity taken when the buffer has to grow, so a cut that creeps up by a
    /// few vertices a step does not recreate the mesh every step.
    private static let headroom = 1.25

    private var mesh: LowLevelMesh
    private(set) var resource: MeshResource
    private var vertexCapacity: Int
    private var indexCapacity: Int
    /// How many indices the last write left drawable — the rest of the buffer's capacity is stale.
    private(set) var indexCount = 0

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
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)]
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

    /// Rewrites the buffer from a freshly clipped set of parts.
    @discardableResult
    func write(_ descriptors: [MeshDescriptor]) throws -> Outcome {
        var vertexCount = 0
        var indexCount = 0
        for descriptor in descriptors {
            vertexCount += descriptor.positions.count
            guard case .triangles(let indices) = descriptor.primitives else { continue }
            indexCount += indices.count
        }
        guard vertexCount > 0, indexCount > 0 else {
            self.indexCount = 0
            return .empty
        }
        self.indexCount = indexCount

        var recreated = false
        if vertexCount > vertexCapacity || indexCount > indexCapacity {
            let vertices = max(Int(Double(vertexCount) * Self.headroom), vertexCapacity)
            let indices = max(Int(Double(indexCount) * Self.headroom), indexCapacity)
            (mesh, resource) = try Self.make(vertexCapacity: vertices, indexCapacity: indices)
            vertexCapacity = vertices
            indexCapacity = indices
            recreated = true
        }

        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let vertices = raw.bindMemory(to: Vertex.self)
            var cursor = 0
            for descriptor in descriptors {
                let positions = descriptor.positions.elements
                let normals = descriptor.normals?.elements
                let uvs = descriptor.textureCoordinates?.elements
                for index in positions.indices {
                    let position = positions[index]
                    let normal = normals?[index] ?? SIMD3<Float>(0, 1, 0)
                    let uv = uvs?[index] ?? .zero
                    vertices[cursor] = Vertex(
                        px: position.x, py: position.y, pz: position.z,
                        nx: normal.x, ny: normal.y, nz: normal.z,
                        u: uv.x, v: uv.y
                    )
                    lower = simd_min(lower, position)
                    upper = simd_max(upper, position)
                    cursor += 1
                }
            }
        }

        mesh.withUnsafeMutableIndices { raw in
            let buffer = raw.bindMemory(to: UInt32.self)
            var cursor = 0
            // Each part's indices are relative to its own vertices, so they shift by however many
            // vertices the parts before it contributed.
            var vertexBase = 0
            for descriptor in descriptors {
                guard case .triangles(let indices) = descriptor.primitives else { continue }
                for index in indices {
                    buffer[cursor] = index + UInt32(vertexBase)
                    cursor += 1
                }
                vertexBase += descriptor.positions.count
            }
        }

        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexCount: indexCount,
                topology: .triangle,
                materialIndex: 0,
                bounds: BoundingBox(min: lower, max: upper)
            )
        ])
        return recreated ? .regrown : .rewritten
    }
}
