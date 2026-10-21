import Foundation
import simd

struct OverlayMesh: Sendable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []
    mutating func reserveCapacity(_ count: Int) {
        positions.reserveCapacity(count); normals.reserveCapacity(count)
        uvs.reserveCapacity(count); indices.reserveCapacity(count)
    }
}

/// Retains an indexed CPU snapshot of the actual visible raster top tessellation.
/// Height refits share the immutable horizontal topology/index; never infer ground from a flat datum.
struct OverlaySurfaceMesh: Sendable {
    let id = UUID()
    let topologyID: UUID
    private let horizontal: [SIMD2<Float>]
    private let sourceIndices: [UInt32]
    private let sourceFaces: [Int]
    private let positionsOverride: [SIMD3<Float>]?
    private struct SurfaceTriangle: Sendable {
        let a: SIMD3<Double>
        let b: SIMD3<Double>
        let c: SIMD3<Double>
        var points: [SIMD2<Double>] { [SIMD2(a.x, a.z), SIMD2(b.x, b.z), SIMD2(c.x, c.z)] }
        let bounds: OverlayBounds
        init(a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>) {
            self.a = a; self.b = b; self.c = c
            var bounds = OverlayBounds(point: SIMD2(a.x, a.z))
            bounds.lo = simd_min(bounds.lo, simd_min(SIMD2(b.x, b.z), SIMD2(c.x, c.z)))
            bounds.hi = simd_max(bounds.hi, simd_max(SIMD2(b.x, b.z), SIMD2(c.x, c.z)))
            self.bounds = bounds
        }
        /// Strict convex SAT rejects shared edges/vertices before upper-envelope subtraction.
        func overlapsInterior(_ other: Self, epsilon: Double, work: inout OverlayWork) throws -> Bool {
            let a = points, b = other.points
            for (clip, subject) in [(a, b), (b, a)] {
                let sign = OverlayMath.cross(clip[1] - clip[0], clip[2] - clip[0]) > 0 ? 1.0 : -1.0
                for edge in 0..<3 {
                    try work.spend(3)
                    let origin = clip[edge], direction = clip[(edge + 1) % 3] - origin
                    if subject.map({ sign * OverlayMath.cross(direction, $0 - origin) }).max()! <= epsilon * epsilon { return false }
                }
            }
            return true
        }
        func boundedHeight(at p: SIMD2<Double>) -> Double {
            min(max(height(at: p), min(a.y, min(b.y, c.y))), max(a.y, max(b.y, c.y)))
        }
        func height(at p: SIMD2<Double>) -> Double {
            let a2 = SIMD2(a.x, a.z), b2 = SIMD2(b.x, b.z), c2 = SIMD2(c.x, c.z)
            let denominator = OverlayMath.cross(b2 - a2, c2 - a2)
            let bWeight = OverlayMath.cross(p - a2, c2 - a2) / denominator
            let cWeight = OverlayMath.cross(b2 - a2, p - a2) / denominator
            return a.y + bWeight * (b.y - a.y) + cWeight * (c.y - a.y)
        }
    }
    private let triangles: [SurfaceTriangle]
    private let index: OverlaySurfaceIndex
    private let preparedWork: OverlayWork
    private let epsilon: Double
    private let resolvesOverlaps: Bool

    var isEmpty: Bool { triangles.isEmpty }

    init(terrain: TerrainSolidGenerator.Buffers, resolvesOverlaps: Bool = false, limits: OverlayGeometryLimits = .init(), reusing previous: OverlaySurfaceMesh? = nil) throws {
        self.resolvesOverlaps = resolvesOverlaps
        var work = try OverlayWork(limits)
        guard terrain.indices.count.isMultiple(of: 3) else { throw OverlayGeometryError.invalidSurface }
        try work.checkTriangles(terrain.indices.count / 3)
        try work.spend(terrain.positions.count)
        guard terrain.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw OverlayGeometryError.nonFiniteInput
        }
        // Heights change each interaction frame; horizontal topology and its search index do
        // not. Keep the new position snapshot and share the immutable face/index storage.
        if !resolvesOverlaps, let previous, !previous.resolvesOverlaps,
           terrain.positions.count == previous.horizontal.count, terrain.indices == previous.sourceIndices,
           zip(terrain.positions, previous.horizontal).allSatisfy({ $0.x == $1.x && $0.z == $1.y }) {
            var cursor = 0
            var matchingFaces = true
            for i in stride(from: 0, to: terrain.indices.count, by: 3) {
                try work.spend()
                let a = SIMD3<Double>(terrain.positions[Int(terrain.indices[i])])
                let b = SIMD3<Double>(terrain.positions[Int(terrain.indices[i + 1])])
                let c = SIMD3<Double>(terrain.positions[Int(terrain.indices[i + 2])])
                let projected = abs(OverlayMath.cross(SIMD2(b.x - a.x, b.z - a.z), SIMD2(c.x - a.x, c.z - a.z)))
                let accepted = projected > max(previous.epsilon * previous.epsilon, simd_length(simd_cross(b - a, c - a)) * 1e-6)
                let wasAccepted = cursor < previous.sourceFaces.count && previous.sourceFaces[cursor] == i
                if accepted != wasAccepted { matchingFaces = false; break }
                if wasAccepted { cursor += 1 }
            }
            if matchingFaces {
                horizontal = previous.horizontal; sourceIndices = previous.sourceIndices; sourceFaces = previous.sourceFaces
                positionsOverride = terrain.positions
                triangles = previous.triangles; index = previous.index
                topologyID = previous.topologyID; epsilon = previous.epsilon; preparedWork = work
                return
            }
        }
        positionsOverride = nil
        horizontal = terrain.positions.map { SIMD2($0.x, $0.z) }
        sourceIndices = terrain.indices
        let points = horizontal.map { SIMD2<Double>($0) }
        epsilon = OverlayBounds(points).epsilon
        var result: [SurfaceTriangle] = []
        var faces: [Int] = []
        result.reserveCapacity(terrain.indices.count / 3)
        for i in stride(from: 0, to: terrain.indices.count, by: 3) {
            try work.spend()
            let ia = Int(terrain.indices[i]), ib = Int(terrain.indices[i + 1]), ic = Int(terrain.indices[i + 2])
            guard terrain.positions.indices.contains(ia), terrain.positions.indices.contains(ib), terrain.positions.indices.contains(ic) else {
                throw OverlayGeometryError.invalidSurface
            }
            let a = SIMD3<Double>(terrain.positions[ia]), b = SIMD3<Double>(terrain.positions[ib]), c = SIMD3<Double>(terrain.positions[ic])
            let triangle = SurfaceTriangle(a: a, b: b, c: c)
            let projectedArea = abs(OverlayMath.cross(SIMD2(b.x - a.x, b.z - a.z), SIMD2(c.x - a.x, c.z - a.z)))
            let area = simd_length(simd_cross(b - a, c - a))
            // A facade rotated/quantized through Float ECEF transforms can retain a numerical
            // horizontal sliver. Its height plane is ill-conditioned and is not usable ground.
            guard projectedArea > max(epsilon * epsilon, area * 1e-6) else { continue }
            result.append(triangle)
            faces.append(i)
        }
        triangles = result
        sourceFaces = faces
        if !resolvesOverlaps, let previous, !previous.resolvesOverlaps,
           previous.horizontal == horizontal, previous.sourceIndices == sourceIndices, previous.sourceFaces == faces {
            index = previous.index
            topologyID = previous.topologyID
        } else {
            index = try OverlaySurfaceIndex(bounds: result.map(\.bounds), hierarchical: resolvesOverlaps, work: &work)
            topologyID = UUID()
        }
        preparedWork = work
    }

    private func surfaceTriangle(at index: Int) -> SurfaceTriangle {
        guard let positions = positionsOverride else { return triangles[index] }
        let offset = sourceFaces[index]
        return SurfaceTriangle(a: SIMD3<Double>(positions[Int(sourceIndices[offset])]),
                               b: SIMD3<Double>(positions[Int(sourceIndices[offset + 1])]),
                               c: SIMD3<Double>(positions[Int(sourceIndices[offset + 2])]))
    }

    /// Highest vertically intersected nonvertical face. Vertical facades have zero horizontal
    /// footprint and cannot supply a ground height; gaps remain absent.
    func surfaceY(atX x: Float, z: Float) -> Float? {
        guard x.isFinite, z.isFinite else { return nil }
        let point = SIMD2<Double>(Double(x), Double(z))
        var work = preparedWork
        guard let candidates = try? index.candidates(for: OverlayBounds([point]), work: &work) else { return nil }
        var result: Double?
        for candidate in candidates {
            let triangle = surfaceTriangle(at: candidate)
            let points = triangle.points
            let sign = OverlayMath.cross(points[1] - points[0], points[2] - points[0]) > 0 ? 1.0 : -1.0
            if points.indices.allSatisfy({ i in
                sign * OverlayMath.cross(points[(i + 1) % 3] - points[i], point - points[i]) >= -epsilon * epsilon
            }) {
                let height = triangle.boundedHeight(at: point)
                if height.isFinite { result = max(result ?? height, height) }
            }
        }
        return result.map(Float.init)
    }

    /// `elevationToY` must come from the active projection (and therefore its frozen datum).
    /// A relative altitude uses the difference of two projected elevations, never a second scale rule.
    /// First clip source footprints through OverlayAreaGeometry. Absolute altitude then needs no
    /// resident ground; the other modes additionally intersect the actual resident top triangles.
    /// `ring` is the validated north-up image extent with unit-square UVs. The resident raster
    /// already has the chunk boundary cut into it; intersecting it with this extent preserves both.
    func drapeImage(_ source: [OverlayTriangle], ring: [OverlayVertex], altitude: AltitudeReference,
                    lift: Double, elevationToY: (Double) -> Double) throws -> OverlayMesh {
        guard !resolvesOverlaps, altitude != .absolute, ring.count == 4,
              ring[0].point.x == ring[3].point.x, ring[1].point.x == ring[2].point.x,
              ring[0].point.y == ring[1].point.y, ring[2].point.y == ring[3].point.y,
              ring.allSatisfy(\.isFinite), lift.isFinite else {
            return try drape(source, altitude: altitude, lift: lift, elevationToY: elevationToY)
        }
        let a = ring[0].point, b = ring[1].point, c = ring[2].point, d = ring[3].point
        let dx = b.x - a.x, dz = d.y - a.y
        guard dx != 0, dz != 0 else { throw OverlayGeometryError.invalidProjection }
        let bounds = OverlayBounds([a, b, c, d])
        var work = preparedWork
        var mesh = OverlayMesh()
        func vertex(_ point: SIMD2<Double>) -> OverlayVertex {
            .init(point: point, uv: .init((point.x - a.x) / dx, (point.y - a.y) / dz), altitude: ring[0].altitude)
        }
        let candidates = try index.candidates(for: bounds, work: &work)
        let vertexCapacity = min(horizontal.count, candidates.count * 3)
        mesh.positions.reserveCapacity(vertexCapacity)
        mesh.normals.reserveCapacity(vertexCapacity)
        mesh.uvs.reserveCapacity(vertexCapacity)
        mesh.indices.reserveCapacity(min(work.limits.maxTriangles, candidates.count * 2) * 3)
        var indexedVertices = [UInt32](repeating: .max, count: horizontal.count)
        let relativeHeight = altitude == .relativeToGround ? elevationToY(ring[0].altitude) - elevationToY(0) : 0
        func indexedVertex(_ source: UInt32, position: SIMD3<Double>) throws -> UInt32 {
            let sourceID = Int(source)
            if indexedVertices[sourceID] != .max { return indexedVertices[sourceID] }
            let point = SIMD3<Float>(Float(position.x), Float(position.y + relativeHeight + lift), Float(position.z))
            let uv = SIMD2<Float>(Float((position.x - a.x) / dx), Float((position.z - a.y) / dz))
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite, uv.x.isFinite, uv.y.isFinite else {
                throw OverlayGeometryError.nonFiniteInput
            }
            guard mesh.positions.count < Int(UInt32.max) else { throw OverlayGeometryError.budgetExceeded }
            let result = UInt32(mesh.positions.count)
            indexedVertices[sourceID] = result
            mesh.positions.append(point); mesh.uvs.append(uv)
            // Image materials are unlit. A common normal lets adjacent terrain faces share
            // vertices without changing their exact positions or visible image shading.
            mesh.normals.append(.init(0, 1, 0))
            return result
        }
        for id in candidates {
            let ground = surfaceTriangle(at: id)
            let triangle = OverlayTriangle(a: vertex(SIMD2(ground.a.x, ground.a.z)),
                b: vertex(SIMD2(ground.b.x, ground.b.z)), c: vertex(SIMD2(ground.c.x, ground.c.z)))
            func emit(_ fragment: OverlayTriangle) throws {
                try Self.append(fragment, lift: lift, mesh: &mesh, work: &work) { vertex in
                    let y = ground.boundedHeight(at: vertex.point)
                    return altitude == .relativeToGround ? y + elevationToY(vertex.altitude) - elevationToY(0) : y
                }
            }
            if ground.bounds.lo.x >= bounds.lo.x, ground.bounds.hi.x <= bounds.hi.x,
               ground.bounds.lo.y >= bounds.lo.y, ground.bounds.hi.y <= bounds.hi.y {
                try work.spend(3)
                try work.checkTriangles(mesh.indices.count / 3 + 1)
                let offset = sourceFaces[id]
                let ia = try indexedVertex(sourceIndices[offset], position: ground.a)
                let ib = try indexedVertex(sourceIndices[offset + 1], position: ground.b)
                let ic = try indexedVertex(sourceIndices[offset + 2], position: ground.c)
                mesh.indices.append(ia)
                if OverlayMath.cross(triangle.b.point - triangle.a.point, triangle.c.point - triangle.a.point) <= 0 {
                    mesh.indices.append(ib); mesh.indices.append(ic)
                } else {
                    mesh.indices.append(ic); mesh.indices.append(ib)
                }
            } else {
                let polygon = try OverlayTriangleIntersection.clip(triangle, a: a, b: b, c: c, d: d, epsilon: epsilon, work: &work)
                guard polygon.count >= 3 else { continue }
                for i in 1..<(polygon.count - 1) {
                    let fragment = OverlayTriangle(a: polygon[0], b: polygon[i], c: polygon[i + 1])
                    guard abs(OverlayMath.cross(fragment.b.point - fragment.a.point, fragment.c.point - fragment.a.point)) > epsilon * epsilon else { continue }
                    try emit(fragment)
                }
            }
        }
        return mesh
    }

    /// `rings` are the validated original area; `source` is its tessellation clipped to the same
    /// chunk boundary as this resident raster. Coverage classification never bridges absent faces.
    func drapeArea(_ source: [OverlayTriangle], rings: [[OverlayVertex]], altitude: AltitudeReference,
                   lift: Double, elevationToY: (Double) -> Double) throws -> OverlayMesh {
        // Interior terrain faces need no polygon tessellation cuts. Variable attribute planes
        // and overlapping photogrammetry still use the general fragment/envelope path.
        guard !resolvesOverlaps, altitude != .absolute, let first = source.first?.a,
              source.allSatisfy({ triangle in triangle.vertices.allSatisfy {
                  $0.uv == first.uv && (altitude == .clampToGround || $0.altitude == first.altitude)
              } }) else { return try drape(source, altitude: altitude, lift: lift, elevationToY: elevationToY) }
        guard lift.isFinite, source.allSatisfy(\.isFinite) else {
            throw OverlayGeometryError.nonFiniteInput
        }
        var work = preparedWork
        try work.checkTriangles(source.count)
        let coverage = try OverlayAreaCoverage(rings: rings, work: &work)
        let convex = OverlayConvexArea(rings)
        let sourceIndex = try convex == nil ? OverlaySpatialIndex(bounds: source.map(\.bounds), work: &work) : nil
        var mesh = OverlayMesh()
        let candidates = try index.candidates(for: coverage.bounds, work: &work)
        mesh.reserveCapacity(min(work.limits.maxTriangles, candidates.count * 2) * 3)
        // Constant unlit fills share original resident corners across interior faces. Boundary
        // fragments retain their exact clipped vertices; no absent terrain face gains indices.
        var interiorVertices: [UInt32: UInt32] = [:]
        interiorVertices.reserveCapacity(min(horizontal.count, candidates.count * 2))
        func interiorVertex(_ source: UInt32, position: SIMD3<Double>) throws -> UInt32 {
            if let existing = interiorVertices[source] { return existing }
            let y = altitude == .relativeToGround ? position.y + elevationToY(first.altitude) - elevationToY(0) : position.y
            let p = SIMD3<Float>(Float(position.x), Float(y + lift), Float(position.z))
            let uv = SIMD2<Float>(first.uv)
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, uv.x.isFinite, uv.y.isFinite else { throw OverlayGeometryError.nonFiniteInput }
            guard mesh.positions.count < Int(UInt32.max) else { throw OverlayGeometryError.budgetExceeded }
            let result = UInt32(mesh.positions.count)
            interiorVertices[source] = result
            mesh.positions.append(p); mesh.uvs.append(uv); mesh.normals.append(.init(0, 1, 0))
            return result
        }
        for candidate in candidates {
            let ground = surfaceTriangle(at: candidate)
            let a = SIMD2(ground.a.x, ground.a.z), b = SIMD2(ground.b.x, ground.b.z), c = SIMD2(ground.c.x, ground.c.z)
            func emit(_ fragment: OverlayTriangle) throws {
                try Self.append(fragment, lift: lift, mesh: &mesh, work: &work) { vertex in
                    let y = ground.boundedHeight(at: vertex.point)
                    return altitude == .relativeToGround ? y + elevationToY(vertex.altitude) - elevationToY(0) : y
                }
            }
            if try !coverage.touches(a: a, b: b, c: c, epsilon: epsilon, work: &work) {
                if try coverage.contains((a + b + c) / 3, work: &work) {
                    try work.spend(3)
                    try work.checkTriangles(mesh.indices.count / 3 + 1)
                    let face = sourceFaces[candidate]
                    let ia = try interiorVertex(sourceIndices[face], position: ground.a)
                    let ib = try interiorVertex(sourceIndices[face + 1], position: ground.b)
                    let ic = try interiorVertex(sourceIndices[face + 2], position: ground.c)
                    mesh.indices.append(ia)
                    if OverlayMath.cross(b - a, c - a) <= 0 {
                        mesh.indices.append(ib); mesh.indices.append(ic)
                    } else {
                        mesh.indices.append(ic); mesh.indices.append(ib)
                    }
                }
                continue
            }
            if let convex {
                let triangle = OverlayTriangle(a: .init(point: a, uv: first.uv, altitude: first.altitude),
                    b: .init(point: b, uv: first.uv, altitude: first.altitude), c: .init(point: c, uv: first.uv, altitude: first.altitude))
                for polygon in try convex.fragments(of: triangle, epsilon: epsilon, work: &work) {
                    for i in 1..<(polygon.count - 1) {
                        let fragment = OverlayTriangle(a: polygon[0], b: polygon[i], c: polygon[i + 1])
                        guard abs(OverlayMath.cross(fragment.b.point - fragment.a.point, fragment.c.point - fragment.a.point)) > epsilon * epsilon else { continue }
                        try emit(fragment)
                    }
                }
                continue
            }
            for sourceID in try sourceIndex!.rasterCandidates(for: ground.bounds, work: &work) {
                let polygon = try OverlayTriangleIntersection.clip(source[sourceID], a: a, b: b, c: c, epsilon: epsilon, work: &work)
                guard polygon.count >= 3 else { continue }
                for i in 1..<(polygon.count - 1) {
                    let fragment = OverlayTriangle(a: polygon[0], b: polygon[i], c: polygon[i + 1])
                    guard abs(OverlayMath.cross(fragment.b.point - fragment.a.point, fragment.c.point - fragment.a.point)) > epsilon * epsilon else { continue }
                    try emit(fragment)
                }
            }
        }
        return mesh
    }

    private struct RasterPatch {
        var source: Int
        var fourth: OverlayVertex?
        var bounds: OverlayBounds
    }

    /// Merge only two triangles whose shared diagonal bounds one strictly convex cell.
    /// Constant attributes make removing that diagonal exact; no ground face is bridged.
    private func ribbonPatches(_ source: [OverlayTriangle], work: inout OverlayWork) throws -> [RasterPatch]? {
        guard !resolvesOverlaps, source.count >= 1_024, let first = source.first?.a,
              source.allSatisfy({ t in
                  t.a.uv == first.uv && t.b.uv == first.uv && t.c.uv == first.uv
                  && t.a.altitude == first.altitude && t.b.altitude == first.altitude && t.c.altitude == first.altitude
              }) else { return nil }
        var patches: [RasterPatch] = []
        patches.reserveCapacity(source.count / 2)
        var i = 0
        while i < source.count {
            try work.spend()
            let t = source[i]
            var fourth: OverlayVertex?
            if i + 1 < source.count {
                let next = source[i + 1]
                if t.a == next.a && t.c == next.b { fourth = next.c }
                if let d = fourth {
                    let a = t.a.point, b = t.b.point, c = t.c.point, d = d.point
                    let turns = SIMD4(OverlayMath.cross(b - a, c - b), OverlayMath.cross(c - b, d - c),
                                      OverlayMath.cross(d - c, a - d), OverlayMath.cross(a - d, b - a))
                    let tolerance = epsilon * epsilon
                    if !(turns.min() > tolerance || turns.max() < -tolerance) { fourth = nil }
                }
            }
            var bounds = t.bounds
            if let fourth {
                bounds.lo = simd_min(bounds.lo, fourth.point); bounds.hi = simd_max(bounds.hi, fourth.point)
            }
            patches.append(.init(source: i, fourth: fourth, bounds: bounds))
            i += fourth == nil ? 1 : 2
        }
        return patches.count < source.count ? patches : nil
    }

    private func drapeRibbon(_ source: [OverlayTriangle], patches: [RasterPatch], altitude: AltitudeReference,
                             lift: Double, elevationToY: (Double) -> Double, work: inout OverlayWork) throws -> OverlayMesh {
        var mesh = OverlayMesh()
        mesh.reserveCapacity(min(work.limits.maxTriangles, source.count * 2) * 2)
        var start = 0
        while start < patches.count {
            var end = start + 1, query = patches[start].bounds
            for next in end..<min(patches.count, start + 4) {
                try work.spend()
                var combined = query
                combined.lo = simd_min(query.lo, patches[next].bounds.lo)
                combined.hi = simd_max(query.hi, patches[next].bounds.hi)
                let extent = combined.hi - combined.lo
                guard max(extent.x, extent.y) <= epsilon * 1e10 / 128 else { break }
                query = combined; end = next + 1
            }
            try index.visitCandidates(for: source[patches[start].source], bounds: query, work: &work) { candidate, work in
                let ground = surfaceTriangle(at: candidate)
                for id in start..<end {
                    try work.spend()
                    let patch = patches[id]
                    guard patch.bounds.intersects(ground.bounds) else { continue }
                    let t = source[patch.source]
                    let a = SIMD2(ground.a.x, ground.a.z), b = SIMD2(ground.b.x, ground.b.z), c = SIMD2(ground.c.x, ground.c.z)
                    let polygon: OverlayTriangleIntersection.Polygon
                    if let fourth = patch.fourth {
                        polygon = try OverlayTriangleIntersection.clipQuad(t, fourth: fourth, a: a, b: b, c: c, epsilon: epsilon, work: &work)
                    } else {
                        polygon = try OverlayTriangleIntersection.clip(t, a: a, b: b, c: c, epsilon: epsilon, work: &work)
                    }
                    guard polygon.count >= 3 else { continue }
                    try work.spend(polygon.count)
                    let vertexLimit = min(work.limits.maxTriangles, Int(UInt32.max) / 3) * 3
                    guard mesh.positions.count <= vertexLimit - polygon.count else { throw OverlayGeometryError.budgetExceeded }
                    let base = UInt32(mesh.positions.count)
                    var normal = simd_cross(ground.b - ground.a, ground.c - ground.a)
                    if normal.y < 0 { normal = -normal }
                    let length = simd_length(normal)
                    guard length > 0, length.isFinite else { throw OverlayGeometryError.invalidSurface }
                    let n = SIMD3<Float>(normal / length)
                    // All vertices lie on this terrain face. Unlit overlays can share fan
                    // corners, just as image overlays share resident terrain vertices.
                    for i in 0..<polygon.count {
                        let v = polygon[i]
                        let y = ground.boundedHeight(at: v.point)
                        let height = altitude == .relativeToGround ? y + elevationToY(v.altitude) - elevationToY(0) : y
                        let p = SIMD3<Float>(Float(v.point.x), Float(height + lift), Float(v.point.y))
                        let uv = SIMD2<Float>(v.uv)
                        guard p.x.isFinite, p.y.isFinite, p.z.isFinite, uv.x.isFinite, uv.y.isFinite else { throw OverlayGeometryError.nonFiniteInput }
                        mesh.positions.append(p); mesh.uvs.append(uv); mesh.normals.append(n)
                    }
                    for i in 1..<(polygon.count - 1) {
                        let area = OverlayMath.cross(polygon[i].point - polygon[0].point, polygon[i + 1].point - polygon[0].point)
                        guard abs(area) > epsilon * epsilon else { continue }
                        let b = base + UInt32(area < 0 ? i : i + 1), c = base + UInt32(area < 0 ? i + 1 : i)
                        let cross = simd_cross(SIMD3<Double>(mesh.positions[Int(b)]) - SIMD3<Double>(mesh.positions[Int(base)]),
                                               SIMD3<Double>(mesh.positions[Int(c)]) - SIMD3<Double>(mesh.positions[Int(base)]))
                        guard cross.y > 0 else { continue }
                        try work.checkTriangles(mesh.indices.count / 3 + 1)
                        mesh.indices.append(base); mesh.indices.append(b); mesh.indices.append(c)
                    }
                }
            }
            start = end
        }
        return mesh
    }

    func drape(_ source: [OverlayTriangle], altitude: AltitudeReference = .clampToGround,
               lift: Double = 0, elevationToY: (Double) -> Double) throws -> OverlayMesh {
        guard lift.isFinite, source.allSatisfy(\.isFinite) else {
            throw OverlayGeometryError.nonFiniteInput
        }
        var work = preparedWork
        // Raster keeps its original limits. Dense, overlapping photogrammetry needs a separate
        // work allowance (measured on the City fixture), while output remains capped at 200k
        // triangles. Cancellation is checked throughout either bounded computation.
        if resolvesOverlaps { work = try OverlayWork(.init(maxOperations: 32_000_000)) }
        try work.checkTriangles(source.count)
        if altitude != .absolute, let patches = try ribbonPatches(source, work: &work) {
            return try drapeRibbon(source, patches: patches, altitude: altitude, lift: lift, elevationToY: elevationToY, work: &work)
        }
        var mesh = OverlayMesh()
        mesh.reserveCapacity(min(work.limits.maxTriangles, max(342, source.count * 3)) * 3)
        if altitude == .absolute {
            for triangle in source {
                try Self.append(triangle, lift: lift, mesh: &mesh, work: &work) { elevationToY($0.altitude) }
            }
            return mesh
        }
        var start = 0
        while start < source.count {
            let first = source[start]
            var end = start + 1, query = first.bounds
            // Adjacent dense-ribbon triangles share nearby terrain faces. Query/load each face
            // once for a small spatial batch, then retain exact per-triangle intersections.
            // Dispersed triangles and overlapping photogrammetry keep one-triangle traversal.
            if !resolvesOverlaps, source.count >= 1_024 {
                for next in end..<min(source.count, start + 8) {
                    try work.spend()
                    let box = source[next].bounds
                    var combined = query
                    combined.lo = simd_min(query.lo, box.lo); combined.hi = simd_max(query.hi, box.hi)
                    let extent = combined.hi - combined.lo
                    guard max(extent.x, extent.y) <= epsilon * 1e10 / 128 else { break }
                    query = combined; end = next + 1
                }
            }
            let range = start..<end
            try index.visitCandidates(for: first, bounds: query, work: &work) { candidate, work in
                let ground = surfaceTriangle(at: candidate)
                for sourceID in range {
                    let triangle = source[sourceID]
                    if range.count > 1 {
                        try work.spend()
                        guard triangle.bounds.intersects(ground.bounds) else { continue }
                    }
                    if !resolvesOverlaps {
                        let polygon = try OverlayTriangleIntersection.clip(triangle,
                            a: SIMD2(ground.a.x, ground.a.z), b: SIMD2(ground.b.x, ground.b.z), c: SIMD2(ground.c.x, ground.c.z),
                            epsilon: epsilon, work: &work)
                        guard polygon.count >= 3 else { continue }
                        var area = 0.0
                        let origin = polygon[0].point
                        for i in 0..<polygon.count {
                            area += OverlayMath.cross(polygon[i].point - origin, polygon[(i + 1) % polygon.count].point - origin) / 2
                        }
                        guard abs(area) > epsilon * epsilon else { continue }
                        for i in 1..<(polygon.count - 1) {
                            let fragment = OverlayTriangle(a: polygon[0], b: polygon[i], c: polygon[i + 1])
                            guard abs(OverlayMath.cross(fragment.b.point - fragment.a.point, fragment.c.point - fragment.a.point)) > epsilon * epsilon else { continue }
                            try Self.append(fragment, lift: lift, mesh: &mesh, work: &work) { vertex in
                                let y = ground.boundedHeight(at: vertex.point)
                                return altitude == .relativeToGround ? y + elevationToY(vertex.altitude) - elevationToY(0) : y
                            }
                        }
                        continue
                    }
                    let polygon = try OverlayAreaGeometry.intersect(triangle, with: ground.points, epsilon: epsilon, work: &work)
                    guard polygon.count >= 3, abs(OverlayMath.area(polygon)) > epsilon * epsilon else { continue }
                    let polygons = resolvesOverlaps ? try visibleFragments(polygon, on: candidate, work: &work) : [polygon]
                    var fragments: [OverlayTriangle] = []
                    for piece in polygons {
                        try OverlayAreaGeometry.appendFan(piece, epsilon: epsilon, result: &fragments, work: &work)
                    }
                    for fragment in fragments {
                        try Self.append(fragment, lift: lift, mesh: &mesh, work: &work) { vertex in
                            switch altitude {
                            case .clampToGround: ground.boundedHeight(at: vertex.point)
                            case .absolute: elevationToY(vertex.altitude)
                            case .relativeToGround:
                                ground.boundedHeight(at: vertex.point) + elevationToY(vertex.altitude) - elevationToY(0)
                            }
                        }
                    }
                }
            }
            start = end
        }
        return mesh
    }

    /// Remove only the part of another face that is actually above this face. Splitting by a
    /// lower face's edges and reassembling both halves needlessly multiplies fragments at every
    /// crossing, even where that face hides nothing.
    private func visibleFragments(_ polygon: [OverlayVertex], on candidate: Int, work: inout OverlayWork) throws -> [[OverlayVertex]] {
        let ground = surfaceTriangle(at: candidate)
        var polygons = [polygon]
        // Restrict the query and subtraction to this actual source/ground intersection. A coarse
        // ground triangle can span an entire city, while one line or fan fragment covers metres.
        for otherID in try index.candidates(for: polygon.map(\.point), work: &work) where otherID != candidate {
            try work.spend()
            let other = triangles[otherID]
            let difference = other.points.map { other.height(at: $0) - ground.height(at: $0) }
            guard difference.max()! > epsilon || (otherID < candidate && difference.max()! >= -epsilon),
                  try ground.overlapsInterior(other, epsilon: epsilon, work: &work) else { continue }
            let higher = try Self.halfPlane(other.points.map { OverlayVertex(point: $0) }, side: { vertex in
                other.height(at: vertex.point) - ground.height(at: vertex.point) + (otherID < candidate ? self.epsilon : -self.epsilon)
            }, epsilon: epsilon, work: &work)
            guard higher.count >= 3 else { continue }
            let mask = try OverlayAreaGeometry.intersect(polygon, with: higher.map(\.point), epsilon: epsilon, work: &work)
            let area = OverlayMath.area(mask)
            guard mask.count >= 3, abs(area) > epsilon * epsilon else { continue }
            let maskPoints = mask.map(\.point), maskBounds = OverlayBounds(maskPoints)
            var next: [[OverlayVertex]] = []
            for subject in polygons {
                try work.spend()
                guard OverlayBounds(subject.map(\.point)).intersects(maskBounds) else { next.append(subject); continue }
                let cut = try OverlayAreaGeometry.intersect(subject, with: maskPoints, epsilon: epsilon, work: &work)
                let cutArea = OverlayMath.area(cut)
                // A disjoint mask must leave this fragment whole. Splitting and reassembling it
                // along unrelated mask planes multiplies the partition for every later roof.
                guard cut.count >= 3, abs(cutArea) > epsilon * epsilon else { next.append(subject); continue }
                if abs(cutArea) >= abs(OverlayMath.area(subject)) - epsilon * epsilon { continue }
                let points = cut.map(\.point), sign = cutArea > 0 ? 1.0 : -1.0
                var remaining = subject
                for edge in points.indices {
                    let a = points[edge], direction = points[(edge + 1) % points.count] - a
                    let side: (OverlayVertex) -> Double = { sign * OverlayMath.cross(direction, $0.point - a) }
                    let outside = try Self.halfPlane(remaining, side: { -side($0) }, epsilon: epsilon, work: &work)
                    if outside.count >= 3, abs(OverlayMath.area(outside)) > epsilon * epsilon { next.append(outside) }
                    remaining = try Self.halfPlane(remaining, side: side, epsilon: epsilon, work: &work)
                    if remaining.count < 3 { break }
                }
            }
            polygons = next
            if polygons.isEmpty { break }
        }
        return polygons
    }

    private static func halfPlane(_ polygon: [OverlayVertex], side: (OverlayVertex) -> Double,
                                  epsilon: Double, work: inout OverlayWork) throws -> [OverlayVertex] {
        guard let last = polygon.last else { return [] }
        var previous = last, previousSide = side(last)
        var output: [OverlayVertex] = []
        for current in polygon {
            try work.spend()
            let currentSide = side(current)
            if (currentSide >= 0) != (previousSide >= 0) {
                output.append(previous.interpolated(to: current, at: previousSide / (previousSide - currentSide)))
            }
            if currentSide >= 0 { output.append(current) }
            previous = current; previousSide = currentSide
        }
        return OverlayMath.normalized(output, epsilon: epsilon)
    }

    private static func append(_ triangle: OverlayTriangle, lift: Double, mesh: inout OverlayMesh,
                               work: inout OverlayWork, height: (OverlayVertex) -> Double) throws {
        try work.spend(3)
        try work.checkTriangles(mesh.indices.count / 3 + 1)
        let a = triangle.a
        let clockwise = OverlayMath.cross(triangle.b.point - a.point, triangle.c.point - a.point) <= 0
        let b = clockwise ? triangle.b : triangle.c
        let c = clockwise ? triangle.c : triangle.b
        let pa = SIMD3<Float>(Float(a.point.x), Float(height(a) + lift), Float(a.point.y))
        let pb = SIMD3<Float>(Float(b.point.x), Float(height(b) + lift), Float(b.point.y))
        let pc = SIMD3<Float>(Float(c.point.x), Float(height(c) + lift), Float(c.point.y))
        let ua = SIMD2<Float>(a.uv), ub = SIMD2<Float>(b.uv), uc = SIMD2<Float>(c.uv)
        guard pa.x.isFinite, pa.y.isFinite, pa.z.isFinite,
              pb.x.isFinite, pb.y.isFinite, pb.z.isFinite,
              pc.x.isFinite, pc.y.isFinite, pc.z.isFinite,
              ua.x.isFinite, ua.y.isFinite, ub.x.isFinite, ub.y.isFinite, uc.x.isFinite, uc.y.isFinite else {
            throw OverlayGeometryError.nonFiniteInput
        }
        // Normalize in Double: tiny clipped fragments can underflow Float's length calculation.
        let cross = simd_cross(SIMD3<Double>(pb) - SIMD3<Double>(pa), SIMD3<Double>(pc) - SIMD3<Double>(pa))
        let length = simd_length(cross)
        guard length > 0 else { return }
        let normal = SIMD3<Float>(cross / length)
        guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else { throw OverlayGeometryError.nonFiniteInput }
        guard mesh.positions.count <= Int(UInt32.max) - 3 else { throw OverlayGeometryError.budgetExceeded }
        let base = UInt32(mesh.positions.count)
        mesh.positions.append(pa); mesh.positions.append(pb); mesh.positions.append(pc)
        mesh.uvs.append(ua); mesh.uvs.append(ub); mesh.uvs.append(uc)
        mesh.normals.append(normal); mesh.normals.append(normal); mesh.normals.append(normal)
        mesh.indices.append(base); mesh.indices.append(base + 1); mesh.indices.append(base + 2)
    }

    func drape(_ source: [OverlayTriangle], using projection: any DioramaProjection,
               altitude: AltitudeReference = .clampToGround, lift: Double = 0) throws -> OverlayMesh {
        try drape(source, altitude: altitude, lift: lift) { Double(projection.y(forElevation: $0)) }
    }
}
