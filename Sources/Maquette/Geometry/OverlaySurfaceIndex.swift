import simd

/// A hierarchical broad phase for dense photogrammetry. Uniform raster buckets contain hundreds
/// of unrelated roof/facade triangles in a city; querying those buckets for every draped fragment
/// repeats that unrelated work. The BVH visits only overlapping bounds and small leaf ranges.
struct OverlaySurfaceIndex: Sendable {
    private struct Item: Sendable {
        var id: Int
        var bounds: OverlayBounds
        var center: SIMD2<Double> { (bounds.lo + bounds.hi) / 2 }
    }
    private struct Node: Sendable {
        var bounds: OverlayBounds
        var start: Int
        var count: Int
        var left = -1
        var right = -1
    }
    private let items: [Item]
    private let nodes: [Node]
    private let raster: OverlaySpatialIndex?

    init(bounds: [OverlayBounds], hierarchical: Bool, work: inout OverlayWork) throws {
        if !hierarchical {
            raster = try OverlaySpatialIndex(bounds: bounds, work: &work)
            items = []; nodes = []
            return
        }
        raster = nil
        var items = bounds.enumerated().map { Item(id: $0.offset, bounds: $0.element) }
        var nodes: [Node] = []
        if !items.isEmpty { _ = try Self.build(items: &items, range: items.indices, nodes: &nodes, work: &work) }
        self.items = items; self.nodes = nodes
    }

    private static func build(items: inout [Item], range: Range<Int>, nodes: inout [Node], work: inout OverlayWork) throws -> Int {
        var bounds = items[range.lowerBound].bounds
        var centers = OverlayBounds([items[range.lowerBound].center])
        for item in items[range] {
            try work.spend()
            bounds.lo = simd_min(bounds.lo, item.bounds.lo); bounds.hi = simd_max(bounds.hi, item.bounds.hi)
            centers.lo = simd_min(centers.lo, item.center); centers.hi = simd_max(centers.hi, item.center)
        }
        let node = nodes.count
        nodes.append(.init(bounds: bounds, start: range.lowerBound, count: range.count))
        guard range.count > 8 else { return node }
        let extent = centers.hi - centers.lo
        let axis = extent.x >= extent.y ? 0 : 1
        guard extent[axis] > 0 else { return node }
        items.replaceSubrange(range, with: items[range].sorted { $0.center[axis] < $1.center[axis] })
        let middle = range.lowerBound + range.count / 2
        let left = try build(items: &items, range: range.lowerBound..<middle, nodes: &nodes, work: &work)
        let right = try build(items: &items, range: middle..<range.upperBound, nodes: &nodes, work: &work)
        nodes[node].count = 0; nodes[node].left = left; nodes[node].right = right
        return node
    }

    func candidates(for bounds: OverlayBounds, work: inout OverlayWork) throws -> [Int] {
        try candidates(bounds: bounds, polygon: nil, work: &work)
    }

    func candidates(for triangle: OverlayTriangle, work: inout OverlayWork) throws -> [Int] {
        try candidates(bounds: triangle.bounds, polygon: triangle.vertices.map(\.point), work: &work)
    }

    func candidates(for polygon: [SIMD2<Double>], work: inout OverlayWork) throws -> [Int] {
        try candidates(bounds: OverlayBounds(polygon), polygon: polygon, work: &work)
    }

    /// Triangle-edge half-planes prune long thin diagonal footprints inside a node, rather than
    /// treating their large axis-aligned rectangles as filled surface.
    private func intersects(_ bounds: OverlayBounds, polygon: [SIMD2<Double>]?, work: inout OverlayWork) throws -> Bool {
        guard let polygon else { return true }
        let origin = polygon[0]
        let area = polygon.indices.reduce(0.0) { $0 + OverlayMath.cross(polygon[$1] - origin, polygon[($1 + 1) % polygon.count] - origin) }
        let sign = area > 0 ? 1.0 : -1.0
        for edge in polygon.indices {
            try work.spend()
            let a = polygon[edge], direction = polygon[(edge + 1) % polygon.count] - a
            let normal = sign * SIMD2(-direction.y, direction.x)
            let corner = SIMD2(normal.x >= 0 ? bounds.hi.x : bounds.lo.x, normal.y >= 0 ? bounds.hi.y : bounds.lo.y)
            if simd_dot(normal, corner - a) < 0 { return false }
        }
        return true
    }

    private func candidates(bounds: OverlayBounds, polygon: [SIMD2<Double>]?, work: inout OverlayWork) throws -> [Int] {
        if let raster { return try raster.candidates(for: bounds, work: &work) }
        guard !nodes.isEmpty else { return [] }
        var pending = [0], result: [Int] = []
        while let next = pending.popLast() {
            try work.spend()
            let node = nodes[next]
            guard node.bounds.intersects(bounds), try intersects(node.bounds, polygon: polygon, work: &work) else { continue }
            if node.count > 0 {
                for item in items[node.start..<(node.start + node.count)] {
                    try work.spend()
                    if item.bounds.intersects(bounds), try intersects(item.bounds, polygon: polygon, work: &work) { result.append(item.id) }
                }
            } else { pending.append(node.left); pending.append(node.right) }
        }
        return result.sorted()
    }
}
