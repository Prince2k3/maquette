import simd

/// Splits a polygon into vertical slabs and triangulates its interior intervals.
/// Holes require no artificial bridge. Every interval is a convex trapezoid (or triangle).
enum OverlayPolygonTessellator {
    static func triangulate(rings: [[OverlayVertex]], limits: OverlayGeometryLimits = .init()) throws -> [OverlayTriangle] {
        var work = try OverlayWork(limits)
        return try triangulate(rings: rings, work: &work)
    }

    static func validated(_ input: [[OverlayVertex]], work: inout OverlayWork) throws -> [[OverlayVertex]] {
        guard !input.isEmpty else { throw OverlayGeometryError.degenerateRing }
        var total = 0
        for ring in input {
            guard ring.count <= work.limits.maxInputVertices - total else { throw OverlayGeometryError.budgetExceeded }
            total += ring.count
            guard ring.allSatisfy(\.isFinite) else { throw OverlayGeometryError.nonFiniteInput }
        }
        let epsilon = OverlayBounds(input.flatMap { $0.map(\.point) }).epsilon
        let rings = input.map { OverlayMath.normalized($0, epsilon: epsilon) }
        for ring in rings {
            guard ring.count >= 3 else { throw OverlayGeometryError.degenerateRing }
            for i in ring.indices {
                let a = ring[i].point, b = ring[(i + 1) % ring.count].point
                let previous = ring[(i + ring.count - 1) % ring.count].point
                if OverlayMath.onSegment(b, previous, a, epsilon: epsilon)
                    || OverlayMath.onSegment(previous, a, b, epsilon: epsilon) {
                    throw OverlayGeometryError.selfIntersection
                }
            }
            guard try !edgesIntersect(ring, epsilon: epsilon, work: &work) else { throw OverlayGeometryError.selfIntersection }
            guard abs(OverlayMath.area(ring)) > epsilon * epsilon else { throw OverlayGeometryError.degenerateRing }
        }
        for i in rings.indices.dropFirst() {
            try work.spend(rings[0].count)
            guard OverlayMath.locate(rings[i][0].point, in: rings[0], epsilon: epsilon) == .inside else {
                throw OverlayGeometryError.invalidHole
            }
            for j in 0..<i {
                if try edgesIntersect(rings[i], other: rings[j], epsilon: epsilon, work: &work) {
                    throw OverlayGeometryError.invalidHole
                }
                if j > 0 {
                    try work.spend(rings[i].count + rings[j].count)
                    if OverlayMath.locate(rings[i][0].point, in: rings[j], epsilon: epsilon) != .outside
                        || OverlayMath.locate(rings[j][0].point, in: rings[i], epsilon: epsilon) != .outside {
                        throw OverlayGeometryError.invalidHole
                    }
                }
            }
        }
        return rings
    }

    /// Epsilon-expanded bounds only reject impossible pairs; the exact predicate still decides.
    private static func edgesIntersect(_ ring: [OverlayVertex], other: [OverlayVertex]? = nil,
                                       epsilon: Double, work: inout OverlayWork) throws -> Bool {
        struct Edge {
            var a: SIMD2<Double>; var b: SIMD2<Double>
            var bounds: OverlayBounds
            var ring: Int; var index: Int; var count: Int
        }
        var edges: [Edge] = []
        for (id, vertices) in ([ring] + (other.map { [$0] } ?? [])).enumerated() {
            for i in vertices.indices {
                try work.spend()
                let a = vertices[i].point, b = vertices[(i + 1) % vertices.count].point
                var box = OverlayBounds(point: a)
                box.lo = simd_min(a, b) - SIMD2(repeating: epsilon)
                box.hi = simd_max(a, b) + SIMD2(repeating: epsilon)
                edges.append(.init(a: a, b: b, bounds: box, ring: id, index: i, count: vertices.count))
            }
        }
        let bounds = OverlayBounds(edges.flatMap { [$0.bounds.lo, $0.bounds.hi] })
        let axis = bounds.hi.x - bounds.lo.x >= bounds.hi.y - bounds.lo.y ? 0 : 1
        let ordered = edges.indices.sorted {
            if edges[$0].bounds.lo[axis] == edges[$1].bounds.lo[axis] { return $0 < $1 }
            return edges[$0].bounds.lo[axis] < edges[$1].bounds.lo[axis]
        }
        var active: [Int] = []
        for i in ordered {
            let a = edges[i]
            active.removeAll { edges[$0].bounds.hi[axis] < a.bounds.lo[axis] }
            for j in active {
                try work.spend()
                let b = edges[j]
                if other != nil {
                    if a.ring == b.ring { continue }
                } else if abs(a.index - b.index) == 1 || abs(a.index - b.index) == a.count - 1 { continue }
                if a.bounds.intersects(b.bounds), OverlayMath.intersects(a.a, a.b, b.a, b.b, epsilon: epsilon) { return true }
            }
            active.append(i)
        }
        return false
    }

    static func triangulate(rings input: [[OverlayVertex]], work: inout OverlayWork) throws -> [OverlayTriangle] {
        let rings = try validated(input, work: &work)
        let vertices = rings.flatMap { $0 }
        let bounds = OverlayBounds(vertices.map(\.point))
        let epsilon = bounds.epsilon
        let xs = Array(Set(vertices.map { $0.point.x })).sorted()
        let edges = rings.flatMap { ring in ring.indices.map { (ring[$0], ring[($0 + 1) % ring.count]) } }
        let ordered = edges.indices.filter { edges[$0].0.point.x != edges[$0].1.point.x }.sorted {
            let a = min(edges[$0].0.point.x, edges[$0].1.point.x), b = min(edges[$1].0.point.x, edges[$1].1.point.x)
            return a == b ? $0 < $1 : a < b
        }
        var cursor = 0, active: [Int] = []
        var result: [OverlayTriangle] = []
        for slab in 0..<(xs.count - 1) {
            let left = xs[slab], right = xs[slab + 1]
            while cursor < ordered.count {
                let id = ordered[cursor], edge = edges[id]
                guard min(edge.0.point.x, edge.1.point.x) <= left else { break }
                try work.spend()
                active.append(id); cursor += 1
            }
            active.removeAll { max(edges[$0].0.point.x, edges[$0].1.point.x) < right }
            var crossings: [(height: Double, a: OverlayVertex, b: OverlayVertex, order: Int)] = []
            for id in active {
                try work.spend()
                let (a, b) = edges[id]
                // Do not materialize an absolute midpoint: adjacent representable coordinates
                // have no representable number between them. Keep the midpoint delta local.
                let t = ((left - a.point.x) + (right - left) / 2) / (b.point.x - a.point.x)
                crossings.append(((a.point.y - bounds.lo.y) + (b.point.y - a.point.y) * t, a, b, id))
            }
            crossings.sort { $0.height == $1.height ? $0.order < $1.order : $0.height < $1.height }
            guard crossings.count.isMultiple(of: 2) else { throw OverlayGeometryError.selfIntersection }
            func sample(_ edge: (height: Double, a: OverlayVertex, b: OverlayVertex, order: Int), _ x: Double) -> OverlayVertex {
                edge.a.interpolated(to: edge.b, at: (x - edge.a.point.x) / (edge.b.point.x - edge.a.point.x))
            }
            for i in stride(from: 0, to: crossings.count, by: 2) {
                let lowLeft = sample(crossings[i], left), lowRight = sample(crossings[i], right)
                let highLeft = sample(crossings[i + 1], left), highRight = sample(crossings[i + 1], right)
                try OverlayMath.appendTriangle(lowLeft, highLeft, highRight, epsilon: epsilon, to: &result, work: &work)
                try OverlayMath.appendTriangle(lowLeft, highRight, lowRight, epsilon: epsilon, to: &result, work: &work)
            }
        }
        return result
    }
}
