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
                for j in ring.indices where j > i + 1 && !(i == 0 && j == ring.count - 1) {
                    try work.spend()
                    let c = ring[j].point, d = ring[(j + 1) % ring.count].point
                    if OverlayMath.intersects(a, b, c, d, epsilon: epsilon) { throw OverlayGeometryError.selfIntersection }
                }
            }
            guard abs(OverlayMath.area(ring)) > epsilon * epsilon else { throw OverlayGeometryError.degenerateRing }
        }
        for i in rings.indices.dropFirst() {
            try work.spend(rings[0].count)
            guard OverlayMath.locate(rings[i][0].point, in: rings[0], epsilon: epsilon) == .inside else {
                throw OverlayGeometryError.invalidHole
            }
            for j in 0..<i {
                for a in rings[i].indices {
                    for b in rings[j].indices {
                        try work.spend()
                        if OverlayMath.intersects(rings[i][a].point, rings[i][(a + 1) % rings[i].count].point,
                                                  rings[j][b].point, rings[j][(b + 1) % rings[j].count].point, epsilon: epsilon) {
                            throw OverlayGeometryError.invalidHole
                        }
                    }
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

    static func triangulate(rings input: [[OverlayVertex]], work: inout OverlayWork) throws -> [OverlayTriangle] {
        let rings = try validated(input, work: &work)
        let vertices = rings.flatMap { $0 }
        let bounds = OverlayBounds(vertices.map(\.point))
        let epsilon = bounds.epsilon
        let xs = Array(Set(vertices.map { $0.point.x })).sorted()
        let edges = rings.flatMap { ring in ring.indices.map { (ring[$0], ring[($0 + 1) % ring.count]) } }
        var result: [OverlayTriangle] = []
        for slab in 0..<(xs.count - 1) {
            let left = xs[slab], right = xs[slab + 1]
            var crossings: [(height: Double, a: OverlayVertex, b: OverlayVertex)] = []
            for (a, b) in edges {
                try work.spend()
                guard a.point.x != b.point.x, min(a.point.x, b.point.x) <= left, max(a.point.x, b.point.x) >= right else { continue }
                // Do not materialize an absolute midpoint: adjacent representable coordinates
                // have no representable number between them. Keep the midpoint delta local.
                let t = ((left - a.point.x) + (right - left) / 2) / (b.point.x - a.point.x)
                crossings.append(((a.point.y - bounds.lo.y) + (b.point.y - a.point.y) * t, a, b))
            }
            crossings.sort { $0.height < $1.height }
            guard crossings.count.isMultiple(of: 2) else { throw OverlayGeometryError.selfIntersection }
            func sample(_ edge: (height: Double, a: OverlayVertex, b: OverlayVertex), _ x: Double) -> OverlayVertex {
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
