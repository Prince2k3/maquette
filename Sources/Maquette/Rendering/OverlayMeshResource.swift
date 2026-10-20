import RealityKit
import simd

/// Overlays can change clipped topology. Retain capacity and update both GPU buffers in place;
/// grow only when needed, without MeshResource.generate's asset compile on each update.
@MainActor
final class OverlayMeshResource {
    private var mesh: LowLevelMesh?
    private(set) var resource: MeshResource?
    func update(_ geometry: OverlayMesh) throws {
        guard !geometry.positions.isEmpty, !geometry.indices.isEmpty else { return }
        let resized = mesh == nil || mesh!.vertexCapacity < geometry.positions.count || mesh!.indexCapacity < geometry.indices.count
        if resized {
            func capacity(_ n: Int) -> Int { var value = 8; while value < n { value *= 2 }; return value }
            var descriptor = LowLevelMesh.Descriptor()
            descriptor.vertexCapacity = capacity(geometry.positions.count)
            descriptor.indexCapacity = capacity(geometry.indices.count)
            descriptor.indexType = .uint32
            descriptor.vertexAttributes = [.init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
                .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
                .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: 24)]
            descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferOffset: 0, bufferStride: 32)]
            mesh = try LowLevelMesh(descriptor: descriptor)
        }
        guard let mesh else { return }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { bytes in
            let vertices = bytes.bindMemory(to: ChunkSurfaceMesh.Vertex.self)
            for i in geometry.positions.indices {
                let p = geometry.positions[i], n = geometry.normals[i], uv = geometry.uvs[i]
                vertices[i] = .init(position: (p.x, p.y, p.z), normal: (n.x, n.y, n.z), uv: (uv.x, uv.y))
            }
        }
        mesh.withUnsafeMutableIndices { bytes in
            let indices = bytes.bindMemory(to: UInt32.self)
            for i in geometry.indices.indices { indices[i] = geometry.indices[i] }
        }
        var lo = geometry.positions[0], hi = lo
        for p in geometry.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        mesh.parts.replaceAll([.init(indexCount: geometry.indices.count, topology: .triangle, bounds: .init(min: lo, max: hi))])
        if resized { resource = try MeshResource(from: mesh) }
    }
}
