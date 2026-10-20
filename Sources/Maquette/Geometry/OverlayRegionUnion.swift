import simd

/// Union of simple stroke patches. Splitting slabs at edge intersections prevents overlapping
/// transparent triangles at joins, caps, and self-crossings. This is internal, not a GIS API.
enum OverlayRegionUnion {
    static func triangulate(_ input: [[OverlayVertex]], work: inout OverlayWork) throws -> [OverlayTriangle] {
        let regions = input.filter { abs(OverlayMath.area($0)) > 1e-20 }
        guard !regions.isEmpty else { return [] }
        guard regions.reduce(0, { $0 + $1.count }) <= work.limits.maxInputVertices else { throw OverlayGeometryError.budgetExceeded }
        let edges = regions.flatMap { ring in ring.indices.map { (ring[$0], ring[($0 + 1) % ring.count]) } }
        let bounds = OverlayBounds(edges.flatMap { [$0.0.point, $0.1.point] })
        let epsilon = bounds.epsilon
        let index = try OverlaySpatialIndex(bounds: edges.map { OverlayBounds([$0.0.point, $0.1.point]) }, work: &work)
        var cuts = Set(edges.map { $0.0.point.x })
        for (i, edge) in edges.enumerated() {
            for j in try index.candidates(for: OverlayBounds([edge.0.point, edge.1.point]), work: &work) where j > i {
                let a = edge.0.point, d = edge.1.point - a, c = edges[j].0.point, e = edges[j].1.point - c
                let denominator = OverlayMath.cross(d, e)
                guard abs(denominator) > epsilon * max(simd_length(d), simd_length(e)) else { continue }
                let t = OverlayMath.cross(c - a, e) / denominator, u = OverlayMath.cross(c - a, d) / denominator
                if t > 0, t < 1, u > 0, u < 1 { cuts.insert(a.x + d.x * t) }
            }
        }
        struct Edge { var a: OverlayVertex; var b: OverlayVertex; var height: Double }
        struct Interval { var low: Edge; var high: Edge }
        let xs = cuts.sorted()
        var result: [OverlayTriangle] = []
        for slab in 1..<xs.count {
            let left = xs[slab - 1], right = xs[slab]
            guard right - left > epsilon else { continue }
            var intervals: [Interval] = []
            for ring in regions {
                var crossings: [Edge] = []
                for i in ring.indices {
                    try work.spend()
                    let a = ring[i], b = ring[(i + 1) % ring.count]
                    guard a.point.x != b.point.x, min(a.point.x, b.point.x) <= left, max(a.point.x, b.point.x) >= right else { continue }
                    let t = ((left - a.point.x) + (right - left) / 2) / (b.point.x - a.point.x)
                    crossings.append(.init(a: a, b: b, height: a.point.y - bounds.lo.y + (b.point.y - a.point.y) * t))
                }
                crossings.sort { $0.height < $1.height }
                guard crossings.count.isMultiple(of: 2) else { throw OverlayGeometryError.selfIntersection }
                for i in stride(from: 0, to: crossings.count, by: 2) { intervals.append(.init(low: crossings[i], high: crossings[i + 1])) }
            }
            intervals.sort { $0.low.height < $1.low.height }
            var merged: [Interval] = []
            for interval in intervals {
                if let last = merged.last, interval.low.height <= last.high.height + epsilon {
                    if interval.high.height > last.high.height { merged[merged.count - 1].high = interval.high }
                } else { merged.append(interval) }
            }
            func sample(_ edge: Edge, _ x: Double) -> OverlayVertex {
                edge.a.interpolated(to: edge.b, at: (x - edge.a.point.x) / (edge.b.point.x - edge.a.point.x))
            }
            for interval in merged {
                let a = sample(interval.low, left), b = sample(interval.low, right)
                let c = sample(interval.high, right), d = sample(interval.high, left)
                try OverlayMath.appendTriangle(a, d, c, epsilon: epsilon, to: &result, work: &work)
                try OverlayMath.appendTriangle(a, c, b, epsilon: epsilon, to: &result, work: &work)
            }
        }
        return result
    }
}
