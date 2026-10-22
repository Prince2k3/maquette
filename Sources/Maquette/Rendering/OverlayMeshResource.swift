import RealityKit
import simd
#if MAQUETTE_PROFILING
import os
#endif

/// Overlays can change clipped topology. Retain capacity and update both GPU buffers in place;
/// grow only when needed, without MeshResource.generate's asset compile on each update.
@MainActor
final class OverlayMeshResource {
    #if MAQUETTE_PROFILING
    private static let signposter = OSSignposter(logger: Logger(maquette: "PointsOfInterest"))
    #endif
    private var mesh: LowLevelMesh?
    private(set) var resource: MeshResource?
    private let makeResource: @MainActor (LowLevelMesh) throws -> MeshResource
    init(makeResource: @escaping @MainActor (LowLevelMesh) throws -> MeshResource = { try MeshResource(from: $0) }) {
        self.makeResource = makeResource
    }
    func update(_ geometry: OverlayMesh, reserveForGrowth: Bool = false) throws {
        guard !geometry.positions.isEmpty, !geometry.indices.isEmpty else { return }
        let resized = mesh == nil || mesh!.vertexCapacity < geometry.positions.count || mesh!.indexCapacity < geometry.indices.count
        #if MAQUETTE_PROFILING
        let resizeInterval = resized ? Self.signposter.beginInterval("OverlayMeshResize", id: Self.signposter.makeSignpostID(),
            "vertices=\(geometry.positions.count) indices=\(geometry.indices.count)") : nil
        defer { if let resizeInterval { Self.signposter.endInterval("OverlayMeshResize", resizeInterval) } }
        #endif
        var candidate = mesh
        if resized {
            func capacity(_ n: Int) throws -> Int {
                let (target, overflow) = n.addingReportingOverflow(reserveForGrowth ? n / 2 : 0)
                guard !overflow else { throw OverlayGeometryError.budgetExceeded }
                var value = 8
                while value < target {
                    guard value <= Int.max / 2 else { throw OverlayGeometryError.budgetExceeded }
                    value *= 2
                }
                return value
            }
            var descriptor = LowLevelMesh.Descriptor()
            // A grow of one buffer must never shrink the other: clipping changes vertex and
            // index counts independently and would otherwise alternate resource allocations.
            descriptor.vertexCapacity = max(mesh?.vertexCapacity ?? 0, try capacity(geometry.positions.count))
            descriptor.indexCapacity = max(mesh?.indexCapacity ?? 0, try capacity(geometry.indices.count))
            descriptor.indexType = .uint32
            descriptor.vertexAttributes = [.init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
                .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
                .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: 24)]
            descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferOffset: 0, bufferStride: 32)]
            candidate = try LowLevelMesh(descriptor: descriptor)
        }
        guard let candidate else { return }
        candidate.withUnsafeMutableBytes(bufferIndex: 0) { bytes in
            let vertices = bytes.bindMemory(to: ChunkSurfaceMesh.Vertex.self)
            for i in geometry.positions.indices {
                let p = geometry.positions[i], n = geometry.normals[i], uv = geometry.uvs[i]
                vertices[i] = .init(position: (p.x, p.y, p.z), normal: (n.x, n.y, n.z), uv: (uv.x, uv.y))
            }
        }
        candidate.withUnsafeMutableIndices { bytes in
            let indices = bytes.bindMemory(to: UInt32.self)
            for i in geometry.indices.indices { indices[i] = geometry.indices[i] }
        }
        var lo = geometry.positions[0], hi = lo
        for p in geometry.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        candidate.parts.replaceAll([.init(indexCount: geometry.indices.count, topology: .triangle, bounds: .init(min: lo, max: hi))])
        if resized {
            let nextResource = try makeResource(candidate)
            // Publish the pair together. A failed conversion must leave the old capacities in
            // place so the next update retries creation rather than refilling an unbound mesh.
            mesh = candidate
            resource = nextResource
        }
    }
}
