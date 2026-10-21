import simd

/// A resident visible-LOD snapshot in the same physical frame as content. Keeping its full
/// triangle soup also supplies sight-line occlusion, including vertical building facades.
struct Tiles3DSurfaceSnapshot: Sendable {
    let buffers: TerrainSolidGenerator.Buffers
    let surface: OverlaySurfaceMesh
    let occlusion: DioramaAnnotationOcclusionIndex

    init(geometry: [TerrainSolidGenerator.Buffers], scale: Float, datum: Float, pan: SIMD2<Float>) throws {
        guard scale.isFinite, scale > 0, datum.isFinite, pan.x.isFinite, pan.y.isFinite else {
            throw OverlayGeometryError.invalidSurface
        }
        // Validate aggregate sizes before allocating or copying a resident set. These limits
        // are deliberately larger than a single overlay's output budget: city tiles contain
        // many faces unrelated to one annotation footprint.
        let triangleLimit = 2_000_000, vertexLimit = 4_000_000
        var vertices = 0, indices = 0
        for tile in geometry {
            guard tile.indices.count.isMultiple(of: 3), tile.positions.count <= vertexLimit - vertices,
                  tile.indices.count <= triangleLimit * 3 - indices,
                  tile.indices.allSatisfy({ Int($0) < tile.positions.count }) else { throw OverlayGeometryError.budgetExceeded }
            vertices += tile.positions.count; indices += tile.indices.count
        }
        var buffers = TerrainSolidGenerator.Buffers()
        buffers.positions.reserveCapacity(vertices); buffers.indices.reserveCapacity(indices)
        for tile in geometry {
            try Task.checkCancellation()
            guard buffers.positions.count + tile.positions.count < Int(UInt32.max) else { throw OverlayGeometryError.budgetExceeded }
            let base = UInt32(buffers.positions.count)
            buffers.positions += tile.positions.map { SIMD3($0.x * scale - pan.x, ($0.y - datum) * scale, $0.z * scale - pan.y) }
            buffers.indices += tile.indices.map { $0 + base }
        }
        self.buffers = buffers
        surface = try OverlaySurfaceMesh(terrain: buffers, resolvesOverlaps: true,
            limits: .init(maxTriangles: triangleLimit, maxOperations: 100_000_000))
        occlusion = DioramaAnnotationOcclusionIndex(positions: buffers.positions, indices: buffers.indices)
        try Task.checkCancellation()
    }
}
