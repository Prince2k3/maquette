import Foundation
import RealityKit
import simd

/// A mesh whose vertices are rewritten every frame while its topology stays fixed.
///
/// Panning changes only heights, normals, and texture coordinates, so rebuilding a `MeshResource`
/// from scratch each frame — which runs a full asset compile — costs far more than the update is
/// worth. `LowLevelMesh` instead exposes the GPU vertex buffer directly, so a pan becomes a memory
/// write over an already-allocated buffer.
@MainActor
final class ChunkSurfaceMesh {
    /// Vertex layout written into the buffer. Tightly packed at 32 bytes so the stride matches the
    /// attribute offsets below; `SIMD3<Float>` is not used because it pads to 16 bytes.
    struct Vertex {
        var position: (Float, Float, Float)
        var normal: (Float, Float, Float)
        var uv: (Float, Float)
    }

    private let mesh: LowLevelMesh
    private let indexCount: Int

    /// The resource to hand to a `ModelEntity`. It stays valid across updates.
    let resource: MeshResource

    /// Creates a mesh sized for the given buffers and fills it with their contents.
    init(buffers: TerrainSolidGenerator.Buffers, name: String) throws {
        guard !buffers.positions.isEmpty, !buffers.indices.isEmpty else {
            throw DioramaError.meshGenerationFailed(reason: "Cannot build \(name) from empty buffers")
        }

        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = buffers.positions.count
        descriptor.indexCapacity = buffers.indices.count
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
            .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: 24),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferOffset: 0, bufferStride: 32)]
        descriptor.indexType = .uint32

        let mesh = try LowLevelMesh(descriptor: descriptor)
        self.mesh = mesh
        self.indexCount = buffers.indices.count

        // Indices are written once — panning never changes the topology.
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            for (offset, value) in buffers.indices.enumerated() {
                indices[offset] = value
            }
        }

        Self.writeVertices(buffers, into: mesh)
        Self.updateParts(mesh, indexCount: buffers.indices.count, positions: buffers.positions)

        self.resource = try MeshResource(from: mesh)
    }

    /// Rewrites the vertex buffer from re-sampled geometry.
    func update(from buffers: TerrainSolidGenerator.Buffers) {
        guard buffers.positions.count == mesh.vertexCapacity else { return }
        Self.writeVertices(buffers, into: mesh)
        Self.updateParts(mesh, indexCount: indexCount, positions: buffers.positions)
    }

    // MARK: - Buffer Writes

    private static func writeVertices(_ buffers: TerrainSolidGenerator.Buffers, into mesh: LowLevelMesh) {
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let vertices = raw.bindMemory(to: Vertex.self)
            buffers.positions.withUnsafeBufferPointer { positions in
                buffers.normals.withUnsafeBufferPointer { normals in
                    buffers.uvs.withUnsafeBufferPointer { uvs in
                        for index in 0..<positions.count {
                            let position = positions[index]
                            let normal = normals[index]
                            let uv = uvs[index]
                            vertices[index] = Vertex(
                                position: (position.x, position.y, position.z),
                                normal: (normal.x, normal.y, normal.z),
                                uv: (uv.x, uv.y)
                            )
                        }
                    }
                }
            }
        }
    }

    /// Refreshes the part's bounds, which RealityKit uses for culling. Panning changes heights, so
    /// stale bounds would eventually cull the chunk at grazing angles.
    private static func updateParts(_ mesh: LowLevelMesh, indexCount: Int, positions: [SIMD3<Float>]) {
        var minimum = positions[0]
        var maximum = positions[0]
        for position in positions.dropFirst() {
            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
        }

        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexCount: indexCount,
                topology: .triangle,
                bounds: BoundingBox(min: minimum, max: maximum)
            )
        ])
    }
}
