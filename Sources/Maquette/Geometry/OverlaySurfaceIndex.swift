import simd

/// A hierarchical broad phase for dense photogrammetry. Uniform raster buckets contain hundreds
/// of unrelated roof/facade triangles in a city; querying those buckets for every draped fragment
/// repeats that unrelated work. The BVH visits only overlapping bounds and small leaf ranges.
struct OverlaySurfaceIndex: Sendable {
    private struct Item: Sendable {
        var id: Int
        var bounds: OverlayBounds
        let center: SIMD2<Double>
        init(id: Int, bounds: OverlayBounds) {
            self.id = id; self.bounds = bounds
            center = (bounds.lo + bounds.hi) / 2
        }
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
        nodes.reserveCapacity(items.count / 4 + 1)
        if !items.isEmpty {
            try items.withUnsafeMutableBufferPointer { storage in
                _ = try Self.build(items: storage, range: storage.indices, nodes: &nodes, work: &work)
            }
        }
        self.items = items; self.nodes = nodes
    }

    private static func build(items: UnsafeMutableBufferPointer<Item>, range: Range<Int>, nodes: inout [Node], work: inout OverlayWork, depth: Int = 0) throws -> Int {
        var bounds = items[range.lowerBound].bounds
        var centers = OverlayBounds(point: items[range.lowerBound].center)
        try work.spend(range.count)
        for index in range {
            if index.isMultiple(of: 1024) { try Task.checkCancellation() }
            let item = items[index]
            bounds.lo = simd_min(bounds.lo, item.bounds.lo); bounds.hi = simd_max(bounds.hi, item.bounds.hi)
            centers.lo = simd_min(centers.lo, item.center); centers.hi = simd_max(centers.hi, item.center)
        }
        let node = nodes.count
        nodes.append(.init(bounds: bounds, start: range.lowerBound, count: range.count))
        guard range.count > 8 else { return node }
        let extent = centers.hi - centers.lo
        let axis = extent.x >= extent.y ? 0 : 1
        guard extent[axis] > 0 else { return node }
        // Spatial splitting needs only one pass. Bound its depth and use median selection for
        // extreme clusters/adjacent floating-point centers, preserving a bounded-depth tree.
        var middle = range.lowerBound
        if depth < 32 {
            let cut = centers.lo[axis] / 2 + centers.hi[axis] / 2
            let storage = items.baseAddress!
            try work.spend(range.count * 3)
            var left = range.lowerBound, right = range.upperBound - 1
            var steps = 0
            while left <= right {
                if steps.isMultiple(of: 1024) { try Task.checkCancellation() }
                steps += 1
                if storage[left].center[axis] < cut { left += 1 }
                else {
                    let value = storage[left]; storage[left] = storage[right]; storage[right] = value
                    right -= 1
                }
            }
            middle = left
        }
        if middle == range.lowerBound || middle == range.upperBound {
            middle = range.lowerBound + range.count / 2
            try partition(items: items, range: range, middle: middle, axis: axis, work: &work)
        }
        let left = try build(items: items, range: range.lowerBound..<middle, nodes: &nodes, work: &work, depth: depth + 1)
        let right = try build(items: items, range: middle..<range.upperBound, nodes: &nodes, work: &work, depth: depth + 1)
        nodes[node].count = 0; nodes[node].left = left; nodes[node].right = right
        return node
    }

    /// Select a median in place. Child bounds are recomputed below, so neither child needs a
    /// full sort. IDs break centroid ties deterministically, including stacked roof triangles.
    private static func partition(items: UnsafeMutableBufferPointer<Item>, range: Range<Int>, middle: Int, axis: Int,
        work: inout OverlayWork
    ) throws {
        let storage = items.baseAddress!
        var low = range.lowerBound, high = range.upperBound - 1
        while low < high {
            let pivot = storage[low + (high - low) / 2]
            var left = low, right = high
            while left <= right {
                try work.spend(2)
                while left <= high && less(storage[left], pivot, axis: axis) { try work.spend(); left += 1 }
                while right >= low && less(pivot, storage[right], axis: axis) { try work.spend(); right -= 1 }
                if left <= right {
                    let value = storage[left]; storage[left] = storage[right]; storage[right] = value
                    left += 1; right -= 1
                }
            }
            if middle <= right { high = right }
            else if middle >= left { low = left }
            else { return }
        }
    }

    @inline(__always)
    private static func less(_ a: Item, _ b: Item, axis: Int) -> Bool {
        a.center[axis] == b.center[axis] ? a.id < b.id : a.center[axis] < b.center[axis]
    }

    func candidates(for bounds: OverlayBounds, work: inout OverlayWork) throws -> [Int] {
        try candidates(bounds: bounds, polygon: nil, work: &work)
    }

    func candidates(for triangle: OverlayTriangle, work: inout OverlayWork) throws -> [Int] {
        if let raster { return try raster.rasterCandidates(for: triangle.bounds, work: &work) }
        return try candidates(bounds: triangle.bounds, polygon: triangle.vertices.map(\.point), work: &work)
    }

    func visitCandidates(for triangle: OverlayTriangle, bounds: OverlayBounds? = nil, work: inout OverlayWork,
                         body: (Int, inout OverlayWork) throws -> Void) throws {
        if let raster { try raster.visitRasterCandidates(for: bounds ?? triangle.bounds, work: &work, body: body) }
        else { for id in try candidates(for: triangle, work: &work) { try body(id, &work) } }
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
        if let raster { return try raster.rasterCandidates(for: bounds, work: &work) }
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
