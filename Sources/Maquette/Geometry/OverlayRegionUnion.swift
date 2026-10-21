import simd

/// Union of simple stroke patches. Splitting slabs at edge intersections prevents overlapping
/// transparent triangles at joins, caps, and self-crossings. This is internal, not a GIS API.
enum OverlayRegionUnion {
    static func triangulate(_ input: [[OverlayVertex]], work: inout OverlayWork) throws -> [OverlayTriangle] {
        let bounds = OverlayBounds(input.flatMap { $0.map(\.point) })
        // Sweep along the longer extent, so a vertical route has the same bounded behavior
        // as its horizontal equivalent. A quarter-turn preserves orientation and attributes.
        if bounds.hi.y - bounds.lo.y > bounds.hi.x - bounds.lo.x {
            let rotated = input.map { ring in ring.map { vertex in
                var value = vertex; value.point = SIMD2(vertex.point.y, -vertex.point.x); return value
            } }
            return try triangulateHorizontally(rotated, work: &work).map { triangle in
                let vertices = triangle.vertices.map { vertex in
                    var value = vertex; value.point = SIMD2(-vertex.point.y, vertex.point.x); return value
                }
                return OverlayTriangle(a: vertices[0], b: vertices[1], c: vertices[2])
            }
        }
        return try triangulateHorizontally(input, work: &work)
    }

    private static func triangulateHorizontally(_ input: [[OverlayVertex]], work: inout OverlayWork) throws -> [OverlayTriangle] {
        let regions = input.filter { abs(OverlayMath.area($0)) > 1e-20 }
        guard !regions.isEmpty else { return [] }
        // These are generated cap/join/segment patches, not additional caller input. Charge
        // their expansion to the operation budget; the source path already passed its input cap.
        try work.spend(regions.reduce(0, { $0 + $1.count }))
        let edges = regions.flatMap { ring in ring.indices.map { (ring[$0], ring[($0 + 1) % ring.count]) } }
        let edgeRegions = regions.enumerated().flatMap { index, ring in ring.map { _ in index } }
        let bounds = OverlayBounds(edges.flatMap { [$0.0.point, $0.1.point] })
        let epsilon = bounds.epsilon
        let edgeBounds = edges.map { OverlayBounds([$0.0.point, $0.1.point]) }
        let ordered = edges.indices.sorted {
            if edgeBounds[$0].lo.x == edgeBounds[$1].lo.x { return $0 < $1 }
            return edgeBounds[$0].lo.x < edgeBounds[$1].lo.x
        }
        var cuts = Set(edges.map { $0.0.point.x })
        var active: [Int] = []
        // Sweep only horizontally overlapping edges. A uniform grid saturates its buckets on
        // densely sampled paths, turning a locally simple stroke into quadratic candidate work.
        for i in ordered {
            let bounds = edgeBounds[i]
            active.removeAll { edgeBounds[$0].hi.x < bounds.lo.x }
            let edge = edges[i]
            for j in active {
                try work.spend()
                guard bounds.intersects(edgeBounds[j]) else { continue }
                let a = edge.0.point, d = edge.1.point - a, c = edges[j].0.point, e = edges[j].1.point - c
                let denominator = OverlayMath.cross(d, e)
                guard abs(denominator) > epsilon * max(simd_length(d), simd_length(e)) else { continue }
                let t = OverlayMath.cross(c - a, e) / denominator, u = OverlayMath.cross(c - a, d) / denominator
                if t > 0, t < 1, u > 0, u < 1 { cuts.insert(a.x + d.x * t) }
            }
            active.append(i)
        }
        struct Edge { var id: Int; var a: OverlayVertex; var b: OverlayVertex; var height: Double }
        struct Interval { var low: Edge; var high: Edge }
        struct Key: Hashable { var low: Int; var high: Int }
        struct Span { var interval: Interval; var left: Double; var right: Double }
        let xs = cuts.sorted()
        var result: [OverlayTriangle] = []
        var pending: [Key: Span] = [:]
        func sample(_ edge: Edge, _ x: Double) -> OverlayVertex {
            edge.a.interpolated(to: edge.b, at: (x - edge.a.point.x) / (edge.b.point.x - edge.a.point.x))
        }
        func append(_ span: Span, result: inout [OverlayTriangle], work: inout OverlayWork) throws {
            let a = sample(span.interval.low, span.left), b = sample(span.interval.low, span.right)
            let c = sample(span.interval.high, span.right), d = sample(span.interval.high, span.left)
            try OverlayMath.appendTriangle(a, d, c, epsilon: epsilon, to: &result, work: &work)
            try OverlayMath.appendTriangle(a, c, b, epsilon: epsilon, to: &result, work: &work)
        }
        active = []
        var nextEdge = 0
        for slab in 1..<xs.count {
            let left = xs[slab - 1], right = xs[slab]
            guard right - left > epsilon else { continue }
            var intervals: [Interval] = []
            // Cuts include all edge endpoints and intersections, so active edges span this
            // entire open slab. Preserve each patch's even-odd intervals before their union.
            active.removeAll { edgeBounds[$0].hi.x <= left }
            while nextEdge < ordered.count, edgeBounds[ordered[nextEdge]].lo.x <= left {
                let index = ordered[nextEdge]
                if edgeBounds[index].hi.x >= right { active.append(index) }
                nextEdge += 1
            }
            var regionCrossings: [Int: [Edge]] = [:]
            for index in active {
                try work.spend()
                let a = edges[index].0, b = edges[index].1
                guard a.point.x != b.point.x, edgeBounds[index].hi.x >= right else { continue }
                let t = ((left - a.point.x) + (right - left) / 2) / (b.point.x - a.point.x)
                regionCrossings[edgeRegions[index], default: []].append(.init(
                    id: index, a: a, b: b, height: a.point.y - bounds.lo.y + (b.point.y - a.point.y) * t))
            }
            for region in regionCrossings.keys.sorted() {
                var crossings = regionCrossings[region]!
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
            // Internal patch endpoints/intersections need cuts for interval ordering, but
            // not output seams when the union's two exterior edges remain identical. Keeping
            // the same edge also preserves the exact interpolation of UV and altitude.
            var next: [Key: Span] = [:]
            for interval in merged {
                let key = Key(low: interval.low.id, high: interval.high.id)
                if var span = pending.removeValue(forKey: key) {
                    if span.right == left {
                        span.right = right
                        next[key] = span
                        continue
                    }
                    try append(span, result: &result, work: &work)
                }
                next[key] = .init(interval: interval, left: left, right: right)
            }
            for key in pending.keys.sorted(by: { $0.low == $1.low ? $0.high < $1.high : $0.low < $1.low }) {
                try append(pending[key]!, result: &result, work: &work)
            }
            pending = next
        }
        for key in pending.keys.sorted(by: { $0.low == $1.low ? $0.high < $1.high : $0.low < $1.low }) {
            try append(pending[key]!, result: &result, work: &work)
        }
        return result
    }
}
