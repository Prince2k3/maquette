import Foundation
import simd

/// Uniform broad-phase buckets. Candidate intersection work remains explicitly bounded.
struct OverlaySpatialIndex: Sendable {
    private var buckets: [Int: [Int]] = [:]
    private let bounds: OverlayBounds
    private let size: Int
    private let itemBounds: [OverlayBounds]
    private var firstCells: [SIMD2<Int>] = []
    init(bounds items: [OverlayBounds], work: inout OverlayWork) throws {
        itemBounds = items
        bounds = OverlayBounds(items.flatMap { [$0.lo, $0.hi] })
        size = max(1, min(128, Int(Double(items.count).squareRoot())))
        firstCells.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            firstCells.append(.init(cell(item.lo.x, axis: 0), cell(item.lo.y, axis: 1)))
            for x in cell(item.lo.x, axis: 0)...cell(item.hi.x, axis: 0) {
                for y in cell(item.lo.y, axis: 1)...cell(item.hi.y, axis: 1) {
                    try work.spend()
                    buckets[y * size + x, default: []].append(index)
                }
            }
        }
    }

    /// Raster triangles have disjoint interiors; their draw order is immaterial. Visit each
    /// candidate only in the first shared bucket, avoiding a Set and sort for every fragment.
    /// The general query keeps its original broad phase/tolerance behavior for ring validation.
    func rasterCandidates(for query: OverlayBounds, work: inout OverlayWork) throws -> [Int] {
        guard bounds.intersects(query) else { return [] }
        let first = SIMD2(cell(query.lo.x, axis: 0), cell(query.lo.y, axis: 1))
        var result: [Int] = []
        for x in first.x...cell(query.hi.x, axis: 0) {
            for y in first.y...cell(query.hi.y, axis: 1) {
                try work.spend()
                for index in buckets[y * size + x, default: []] {
                    try work.spend()
                    let owner = SIMD2(max(first.x, firstCells[index].x), max(first.y, firstCells[index].y))
                    if owner.x == x, owner.y == y, itemBounds[index].intersects(query) { result.append(index) }
                }
            }
        }
        return result
    }
    private func cell(_ value: Double, axis: Int) -> Int {
        let span = bounds.hi[axis] - bounds.lo[axis]
        guard span > 0 else { return 0 }
        return Int(max(0, min(Double(size - 1), floor((value - bounds.lo[axis]) / span * Double(size)))))
    }
    func candidates(for query: OverlayBounds, work: inout OverlayWork) throws -> [Int] {
        guard bounds.intersects(query) else { return [] }
        var result = Set<Int>()
        for x in cell(query.lo.x, axis: 0)...cell(query.hi.x, axis: 0) {
            for y in cell(query.lo.y, axis: 1)...cell(query.hi.y, axis: 1) {
                try work.spend()
                for index in buckets[y * size + x, default: []] { try work.spend(); result.insert(index) }
            }
        }
        return result.sorted()
    }
}

enum OverlayAreaGeometry {
    static func clip(_ source: [OverlayTriangle], boundary: [OverlayVertex],
                     limits: OverlayGeometryLimits = .init()) throws -> [OverlayTriangle] {
        var work = try OverlayWork(limits)
        return try clip(source, boundary: boundary, work: &work)
    }
    static func clip(_ source: [OverlayTriangle], boundary: [OverlayVertex], work: inout OverlayWork) throws -> [OverlayTriangle] {
        try work.checkTriangles(source.count)
        guard source.allSatisfy(\.isFinite) else { throw OverlayGeometryError.nonFiniteInput }
        let mask = try OverlayPolygonTessellator.triangulate(rings: [boundary], work: &work)
        let index = try OverlaySpatialIndex(bounds: mask.map(\.bounds), work: &work)
        let epsilon = OverlayBounds(boundary.map(\.point)).epsilon
        var result: [OverlayTriangle] = []
        for triangle in source {
            for candidate in try index.rasterCandidates(for: triangle.bounds, work: &work) {
                let clip = mask[candidate]
                let polygon = try OverlayTriangleIntersection.clip(triangle, a: clip.a.point, b: clip.b.point, c: clip.c.point, epsilon: epsilon, work: &work)
                guard polygon.count >= 3 else { continue }
                for i in 1..<(polygon.count - 1) {
                    try OverlayMath.appendTriangle(polygon[0], polygon[i], polygon[i + 1], epsilon: epsilon, to: &result, work: &work)
                }
            }
        }
        return result
    }

    /// A triangular subject and convex clip polygon. A concave ring is never used as a clip region.
    static func intersect(_ triangle: OverlayTriangle, with clip: [SIMD2<Double>],
                          epsilon: Double, work: inout OverlayWork) throws -> [OverlayVertex] {
        try intersect(triangle.vertices, with: clip, epsilon: epsilon, work: &work)
    }

    static func intersect(_ polygon: [OverlayVertex], with clip: [SIMD2<Double>],
                          epsilon: Double, work: inout OverlayWork) throws -> [OverlayVertex] {
        var output = polygon
        guard clip.count >= 3 else { return [] }
        let origin = clip[0]
        let orientation = clip.indices.reduce(0.0) { result, index in
            result + OverlayMath.cross(clip[index] - origin, clip[(index + 1) % clip.count] - origin)
        }
        guard abs(orientation) > epsilon * epsilon else { return [] }
        let sign = orientation > 0 ? 1.0 : -1.0
        for i in clip.indices {
            guard output.count >= 3 else { return [] }
            let a = clip[i], direction = clip[(i + 1) % clip.count] - a
            let input = output
            output = []
            var previous = input[input.count - 1]
            var previousSide = sign * OverlayMath.cross(direction, previous.point - a)
            for current in input {
                try work.spend()
                let side = sign * OverlayMath.cross(direction, current.point - a)
                // Use the same exact half-plane on both sides of a shared edge; expanding each
                // region by epsilon would create overlapping slivers along every terrain diagonal.
                if (side >= 0) != (previousSide >= 0) {
                    output.append(previous.interpolated(to: current, at: previousSide / (previousSide - side)))
                }
                if side >= 0 { output.append(current) }
                previous = current; previousSide = side
            }
            output = OverlayMath.normalized(output, epsilon: epsilon)
        }
        return output
    }

    static func appendFan(_ polygon: [OverlayVertex], epsilon: Double,
                          result: inout [OverlayTriangle], work: inout OverlayWork) throws {
        guard polygon.count >= 3 else { return }
        for i in 1..<(polygon.count - 1) {
            try OverlayMath.appendTriangle(polygon[0], polygon[i], polygon[i + 1], epsilon: epsilon, to: &result, work: &work)
        }
    }
}
