import simd

struct OverlayMesh: Sendable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []
}

/// Retains an indexed CPU snapshot of the actual visible raster top tessellation.
/// Rebuild the snapshot when its heights/topology change; never infer ground from a flat datum.
struct OverlaySurfaceMesh: Sendable {
    private struct SurfaceTriangle: Sendable {
        let a: SIMD3<Double>
        let b: SIMD3<Double>
        let c: SIMD3<Double>
        var points: [SIMD2<Double>] { [SIMD2(a.x, a.z), SIMD2(b.x, b.z), SIMD2(c.x, c.z)] }
        var bounds: OverlayBounds { OverlayBounds(points) }
        func height(at p: SIMD2<Double>) -> Double {
            let a2 = SIMD2(a.x, a.z), b2 = SIMD2(b.x, b.z), c2 = SIMD2(c.x, c.z)
            let denominator = OverlayMath.cross(b2 - a2, c2 - a2)
            let bWeight = OverlayMath.cross(p - a2, c2 - a2) / denominator
            let cWeight = OverlayMath.cross(b2 - a2, p - a2) / denominator
            return a.y + bWeight * (b.y - a.y) + cWeight * (c.y - a.y)
        }
    }
    private let triangles: [SurfaceTriangle]
    private let index: OverlaySpatialIndex
    private let preparedWork: OverlayWork
    private let epsilon: Double

    init(terrain: TerrainSolidGenerator.Buffers, limits: OverlayGeometryLimits = .init()) throws {
        var work = try OverlayWork(limits)
        guard terrain.indices.count.isMultiple(of: 3) else { throw OverlayGeometryError.invalidSurface }
        try work.checkTriangles(terrain.indices.count / 3)
        try work.spend(terrain.positions.count)
        guard terrain.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw OverlayGeometryError.nonFiniteInput
        }
        let points = terrain.positions.map { SIMD2(Double($0.x), Double($0.z)) }
        epsilon = OverlayBounds(points).epsilon
        var result: [SurfaceTriangle] = []
        for i in stride(from: 0, to: terrain.indices.count, by: 3) {
            try work.spend()
            let ids = (0..<3).map { Int(terrain.indices[i + $0]) }
            guard ids.allSatisfy({ terrain.positions.indices.contains($0) }) else { throw OverlayGeometryError.invalidSurface }
            let p = ids.map { SIMD3<Double>(terrain.positions[$0]) }
            let triangle = SurfaceTriangle(a: p[0], b: p[1], c: p[2])
            let planar = triangle.points
            guard abs(OverlayMath.cross(planar[1] - planar[0], planar[2] - planar[0])) > epsilon * epsilon else { continue }
            result.append(triangle)
        }
        triangles = result
        index = try OverlaySpatialIndex(bounds: result.map(\.bounds), work: &work)
        preparedWork = work
    }

    /// `elevationToY` must come from the active projection (and therefore its frozen datum).
    /// A relative altitude uses the difference of two projected elevations, never a second scale rule.
    /// First clip source footprints through OverlayAreaGeometry. Absolute altitude then needs no
    /// resident ground; the other modes additionally intersect the actual resident top triangles.
    func drape(_ source: [OverlayTriangle], altitude: AltitudeReference = .clampToGround,
               lift: Double = 0, elevationToY: (Double) -> Double) throws -> OverlayMesh {
        guard lift.isFinite, source.allSatisfy({ $0.vertices.allSatisfy(\.isFinite) }) else {
            throw OverlayGeometryError.nonFiniteInput
        }
        var work = preparedWork
        try work.checkTriangles(source.count)
        var mesh = OverlayMesh()
        if altitude == .absolute {
            for triangle in source {
                try Self.append(triangle, lift: lift, mesh: &mesh, work: &work) { elevationToY($0.altitude) }
            }
            return mesh
        }
        for triangle in source {
            for candidate in try index.candidates(for: triangle.bounds, work: &work) {
                let ground = triangles[candidate]
                guard triangle.bounds.intersects(ground.bounds) else { continue }
                let polygon = try OverlayAreaGeometry.intersect(triangle, with: ground.points, epsilon: epsilon, work: &work)
                var fragments: [OverlayTriangle] = []
                try OverlayAreaGeometry.appendFan(polygon, epsilon: epsilon, result: &fragments, work: &work)
                for fragment in fragments {
                    try Self.append(fragment, lift: lift, mesh: &mesh, work: &work) { vertex in
                        switch altitude {
                        case .clampToGround: ground.height(at: vertex.point)
                        case .absolute: elevationToY(vertex.altitude)
                        case .relativeToGround:
                            ground.height(at: vertex.point) + elevationToY(vertex.altitude) - elevationToY(0)
                        }
                    }
                }
            }
        }
        return mesh
    }

    private static func append(_ triangle: OverlayTriangle, lift: Double, mesh: inout OverlayMesh,
                               work: inout OverlayWork, height: (OverlayVertex) -> Double) throws {
        try work.spend(3)
        try work.checkTriangles(mesh.indices.count / 3 + 1)
        let vertices = OverlayMath.cross(triangle.b.point - triangle.a.point, triangle.c.point - triangle.a.point) <= 0
            ? triangle.vertices : [triangle.a, triangle.c, triangle.b]
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        for vertex in vertices {
            let p = SIMD3<Float>(Float(vertex.point.x), Float(height(vertex) + lift), Float(vertex.point.y))
            let uv = SIMD2<Float>(vertex.uv)
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, uv.x.isFinite, uv.y.isFinite else {
                throw OverlayGeometryError.nonFiniteInput
            }
            positions.append(p); uvs.append(uv)
        }
        let cross = simd_cross(positions[1] - positions[0], positions[2] - positions[0])
        guard simd_length(cross) > 0 else { return } // Float output may collapse a subpixel sliver.
        let normal = simd_normalize(cross)
        guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else { throw OverlayGeometryError.nonFiniteInput }
        guard mesh.positions.count <= Int(UInt32.max) - 3 else { throw OverlayGeometryError.budgetExceeded }
        let base = UInt32(mesh.positions.count)
        mesh.positions.append(contentsOf: positions); mesh.uvs.append(contentsOf: uvs)
        mesh.normals.append(contentsOf: [normal, normal, normal])
        mesh.indices.append(contentsOf: [base, base + 1, base + 2])
    }

    func drape(_ source: [OverlayTriangle], using projection: any DioramaProjection,
               altitude: AltitudeReference = .clampToGround, lift: Double = 0) throws -> OverlayMesh {
        try drape(source, altitude: altitude, lift: lift) { Double(projection.y(forElevation: $0)) }
    }
}
