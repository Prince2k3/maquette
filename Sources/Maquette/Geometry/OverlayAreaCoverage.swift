import simd

/// Exact coverage classification of validated area rings. Row bins make point-in-area queries
/// local; the edge index identifies terrain faces requiring actual boundary intersection.
struct OverlayAreaCoverage {
    struct Edge { var a: SIMD2<Double>; var b: SIMD2<Double> }
    let bounds: OverlayBounds
    private let edges: [Edge]
    private let index: OverlaySpatialIndex
    private let rows: [[Int]]

    init(rings: [[OverlayVertex]], work: inout OverlayWork) throws {
        edges = rings.flatMap { ring in ring.indices.map { Edge(a: ring[$0].point, b: ring[($0 + 1) % ring.count].point) } }
        bounds = OverlayBounds(edges.flatMap { [$0.a, $0.b] })
        index = try OverlaySpatialIndex(bounds: edges.map { OverlayBounds([$0.a, $0.b]) }, work: &work)
        let count = max(1, min(256, Int(Double(edges.count).squareRoot())))
        var rows = [[Int]](repeating: [], count: count)
        for (id, edge) in edges.enumerated() {
            let lo = Self.row(min(edge.a.y, edge.b.y), bounds: bounds, count: count)
            let hi = Self.row(max(edge.a.y, edge.b.y), bounds: bounds, count: count)
            for row in lo...hi { try work.spend(); rows[row].append(id) }
        }
        self.rows = rows
    }

    private static func row(_ y: Double, bounds: OverlayBounds, count: Int) -> Int {
        guard bounds.hi.y > bounds.lo.y else { return 0 }
        return Int(max(0, min(Double(count - 1), floor((y - bounds.lo.y) / (bounds.hi.y - bounds.lo.y) * Double(count)))))
    }

    func contains(_ point: SIMD2<Double>, work: inout OverlayWork) throws -> Bool {
        guard point.x >= bounds.lo.x, point.x <= bounds.hi.x, point.y >= bounds.lo.y, point.y <= bounds.hi.y else { return false }
        var inside = false
        for id in rows[Self.row(point.y, bounds: bounds, count: rows.count)] {
            try work.spend()
            let edge = edges[id], a = edge.a, b = edge.b
            if (a.y > point.y) != (b.y > point.y), point.x < a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y) {
                inside.toggle()
            }
        }
        return inside
    }

    func touches(a: SIMD2<Double>, b: SIMD2<Double>, c: SIMD2<Double>, epsilon: Double, work: inout OverlayWork) throws -> Bool {
        var box = OverlayBounds([a, b, c])
        box.lo -= SIMD2(repeating: epsilon); box.hi += SIMD2(repeating: epsilon)
        let sign = OverlayMath.cross(b - a, c - a) > 0 ? 1.0 : -1.0
        func inside(_ p: SIMD2<Double>) -> Bool {
            sign * OverlayMath.cross(b - a, p - a) >= -epsilon * epsilon
                && sign * OverlayMath.cross(c - b, p - b) >= -epsilon * epsilon
                && sign * OverlayMath.cross(a - c, p - c) >= -epsilon * epsilon
        }
        for id in try index.rasterCandidates(for: box, work: &work) {
            try work.spend()
            let edge = edges[id]
            if inside(edge.a) || inside(edge.b)
                || OverlayMath.intersects(edge.a, edge.b, a, b, epsilon: epsilon)
                || OverlayMath.intersects(edge.a, edge.b, b, c, epsilon: epsilon)
                || OverlayMath.intersects(edge.a, edge.b, c, a, epsilon: epsilon) { return true }
        }
        return false
    }
}
