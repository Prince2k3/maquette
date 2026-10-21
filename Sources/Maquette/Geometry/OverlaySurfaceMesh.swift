import Foundation
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
    let id = UUID()
    private struct SurfaceTriangle: Sendable {
        let a: SIMD3<Double>
        let b: SIMD3<Double>
        let c: SIMD3<Double>
        var points: [SIMD2<Double>] { [SIMD2(a.x, a.z), SIMD2(b.x, b.z), SIMD2(c.x, c.z)] }
        var bounds: OverlayBounds { OverlayBounds(points) }
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

    init(terrain: TerrainSolidGenerator.Buffers, resolvesOverlaps: Bool = false, limits: OverlayGeometryLimits = .init()) throws {
        self.resolvesOverlaps = resolvesOverlaps
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
            let projectedArea = abs(OverlayMath.cross(planar[1] - planar[0], planar[2] - planar[0]))
            let area = simd_length(simd_cross(p[1] - p[0], p[2] - p[0]))
            // A facade rotated/quantized through Float ECEF transforms can retain a numerical
            // horizontal sliver. Its height plane is ill-conditioned and is not usable ground.
            guard projectedArea > max(epsilon * epsilon, area * 1e-6) else { continue }
            result.append(triangle)
        }
        triangles = result
        index = try OverlaySurfaceIndex(bounds: result.map(\.bounds), hierarchical: resolvesOverlaps, work: &work)
        preparedWork = work
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
            let triangle = triangles[candidate]
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
    func drape(_ source: [OverlayTriangle], altitude: AltitudeReference = .clampToGround,
               lift: Double = 0, elevationToY: (Double) -> Double) throws -> OverlayMesh {
        guard lift.isFinite, source.allSatisfy({ $0.vertices.allSatisfy(\.isFinite) }) else {
            throw OverlayGeometryError.nonFiniteInput
        }
        var work = preparedWork
        // Raster keeps its original limits. Dense, overlapping photogrammetry needs a separate
        // work allowance (measured on the City fixture), while output remains capped at 200k
        // triangles. Cancellation is checked throughout either bounded computation.
        if resolvesOverlaps { work = try OverlayWork(.init(maxOperations: 32_000_000)) }
        try work.checkTriangles(source.count)
        var mesh = OverlayMesh()
        if altitude == .absolute {
            for triangle in source {
                try Self.append(triangle, lift: lift, mesh: &mesh, work: &work) { elevationToY($0.altitude) }
            }
            return mesh
        }
        for triangle in source {
            for candidate in try index.candidates(for: triangle, work: &work) {
                let ground = triangles[candidate]
                guard triangle.bounds.intersects(ground.bounds) else { continue }
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
        return mesh
    }

    /// Remove only the part of another face that is actually above this face. Splitting by a
    /// lower face's edges and reassembling both halves needlessly multiplies fragments at every
    /// crossing, even where that face hides nothing.
    private func visibleFragments(_ polygon: [OverlayVertex], on candidate: Int, work: inout OverlayWork) throws -> [[OverlayVertex]] {
        let ground = triangles[candidate]
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
        // Tiny finite clipped fragments can underflow Float's reciprocal-square-root normal
        // calculation. Normalize in Double, then store the unit normal in the Float mesh.
        let doublePositions = positions.map { SIMD3<Double>($0) }
        let cross = simd_cross(doublePositions[1] - doublePositions[0], doublePositions[2] - doublePositions[0])
        let length = simd_length(cross)
        guard length > 0 else { return } // Float output may collapse a subpixel sliver.
        let normal = SIMD3<Float>(cross / length)
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
