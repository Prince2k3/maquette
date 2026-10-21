import simd

/// Validated convex rings can cut a terrain face directly. This avoids the artificial slab
/// boundaries of the general tessellation; variable attributes and concavities use that path.
struct OverlayConvexArea {
    struct Plane {
        var origin: SIMD2<Double>
        var normal: SIMD2<Double>
        func side(_ vertex: OverlayVertex) -> Double { simd_dot(normal, vertex.point - origin) }
        func range(in bounds: OverlayBounds) -> SIMD2<Double> {
            let low = SIMD2(normal.x >= 0 ? bounds.lo.x : bounds.hi.x, normal.y >= 0 ? bounds.lo.y : bounds.hi.y)
            let high = SIMD2(normal.x >= 0 ? bounds.hi.x : bounds.lo.x, normal.y >= 0 ? bounds.hi.y : bounds.lo.y)
            return .init(simd_dot(normal, low - origin), simd_dot(normal, high - origin))
        }
    }
    /// Ordered bounds over half-plane coefficients. Whole nodes can be skipped only when
    /// their conservative interval proves every contained plane leaves the query untouched.
    struct PlaneTree {
        struct Node {
            var lower: SIMD4<Double>
            var upper: SIMD4<Double>
            var range: Range<Int>
            var escape: Int
        }
        let reference: SIMD2<Double>
        let nodes: [Node]
        init?(_ planes: [Plane], bounds: OverlayBounds) {
            guard planes.count >= 32 else { return nil }
            let reference = bounds.lo / 2 + bounds.hi / 2
            let coefficients = planes.map { plane in
                let delta = plane.origin - reference, products = plane.normal * delta
                // Preserve magnitudes before cancellation in the offset's dot product.
                return SIMD4(plane.normal.x, plane.normal.y, -simd_dot(plane.normal, delta), abs(products.x) + abs(products.y))
            }
            guard reference.x.isFinite, reference.y.isFinite,
                  coefficients.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite && ($0.x != 0 || $0.y != 0) }) else { return nil }
            var nodes: [Node] = []
            nodes.reserveCapacity(planes.count / 2)
            func append(_ range: Range<Int>) {
                let id = nodes.count
                nodes.append(.init(lower: .zero, upper: .zero, range: range, escape: 0))
                var lower: SIMD4<Double>, upper: SIMD4<Double>
                if range.count <= 8 {
                    lower = coefficients[range.lowerBound]; upper = lower
                    for i in range.dropFirst() { lower = simd_min(lower, coefficients[i]); upper = simd_max(upper, coefficients[i]) }
                } else {
                    let middle = range.lowerBound + range.count / 2
                    let left = nodes.count; append(range.lowerBound..<middle)
                    let right = nodes.count; append(middle..<range.upperBound)
                    lower = simd_min(nodes[left].lower, nodes[right].lower)
                    upper = simd_max(nodes[left].upper, nodes[right].upper)
                }
                nodes[id].lower = lower; nodes[id].upper = upper; nodes[id].escape = nodes.count
            }
            append(planes.indices)
            self.reference = reference; self.nodes = nodes
        }
        func interval(_ node: Node, box: OverlayBounds, epsilon: Double) -> SIMD2<Double>? {
            let a = box.lo - reference, b = box.hi - reference
            let x = SIMD4(node.lower.x * a.x, node.lower.x * b.x, node.upper.x * a.x, node.upper.x * b.x)
            let y = SIMD4(node.lower.y * a.y, node.lower.y * b.y, node.upper.y * a.y, node.upper.y * b.y)
            let low = x.min() + y.min() + node.lower.z, high = x.max() + y.max() + node.upper.z
            // Widen beyond subtraction/product roundoff, including distant origins. Ambiguous
            // or nonfinite intervals always descend to the original exact plane predicates.
            let magnitude = max(max(abs(box.lo.x), abs(box.lo.y)), max(abs(box.hi.x), abs(box.hi.y)))
                + max(abs(reference.x), abs(reference.y))
            let normals = max(abs(node.lower.x), abs(node.upper.x)) + max(abs(node.lower.y), abs(node.upper.y))
            let padding = max(Double.leastNonzeroMagnitude * 64,
                max(epsilon, magnitude * Double.ulpOfOne * 64) * normals
                + (max(abs(node.lower.z), abs(node.upper.z)) + node.upper.w) * Double.ulpOfOne * 64)
            guard low.isFinite, high.isFinite, padding.isFinite else { return nil }
            return .init(low - padding, high + padding)
        }
    }
    fileprivate enum Classification { case outside, inside, crossing([Plane]) }
    enum Intersection { case empty, whole, clipped([[OverlayVertex]]) }
    struct Region {
        fileprivate let bounds: OverlayBounds
        fileprivate let rings: [Classification]
    }
    private let trees: [PlaneTree?]
    private let rings: [[Plane]]
    private let bounds: [OverlayBounds]
    private let interiors: [OverlayBounds?]

    init?(_ input: [[OverlayVertex]]) {
        let epsilon = OverlayBounds(input.flatMap { $0.map(\.point) }).epsilon
        let input = input.map { OverlayMath.normalized($0, epsilon: epsilon) }
        var rings: [[Plane]] = []
        for ring in input {
            guard ring.count >= 3 else { return nil }
            let sign = OverlayMath.area(ring) > 0 ? 1.0 : -1.0
            var planes: [Plane] = []
            for i in ring.indices {
                let a = ring[i].point, b = ring[(i + 1) % ring.count].point
                let c = ring[(i + 2) % ring.count].point
                guard sign * OverlayMath.cross(b - a, c - b) >= 0 else { return nil }
                let edge = b - a
                planes.append(.init(origin: a, normal: sign * SIMD2(-edge.y, edge.x)))
            }
            rings.append(planes)
        }
        guard !rings.isEmpty else { return nil }
        self.rings = rings
        let bounds = input.map { OverlayBounds($0.map(\.point)) }
        self.bounds = bounds
        trees = zip(rings, bounds).map { PlaneTree($0.0, bounds: $0.1) }
        interiors = zip(rings, bounds).map { planes, bounds in
            let center = bounds.lo / 2 + bounds.hi / 2
            let half = bounds.hi / 2 - bounds.lo / 2
            var scale = 1.0
            for plane in planes {
                let reach = simd_dot(simd_abs(plane.normal), half)
                let side = plane.side(.init(point: center))
                guard reach.isFinite, side.isFinite, reach > 0, side > 0 else { return nil }
                scale = min(scale, side / reach)
            }
            let delta = half * (scale * (1 - 1e-8))
            let interior = OverlayBounds([center - delta, center + delta])
            guard interior.lo.x.isFinite, interior.lo.y.isFinite, interior.hi.x.isFinite, interior.hi.y.isFinite,
                  interior.lo.x < interior.hi.x, interior.lo.y < interior.hi.y,
                  planes.allSatisfy({ plane in
                      let range = plane.range(in: interior)
                      return range.x.isFinite && range.y.isFinite && range.x > 0
                  }) else { return nil }
            return interior
        }
    }

    var exteriorBounds: OverlayBounds { bounds[0] }

    private func classify(_ ring: Int, box: OverlayBounds, epsilon: Double, strictInterior: Bool = false, work: inout OverlayWork) throws -> Classification {
        if let interior = interiors[ring], box.lo.x >= interior.lo.x, box.lo.y >= interior.lo.y,
           box.hi.x <= interior.hi.x, box.hi.y <= interior.hi.y {
            // Original plane ranges certify this rectangle strictly inside every half-plane.
            // Their corner arithmetic is monotonic for contained finite query bounds.
            try work.spend()
            return .inside
        }
        var crossing: [Plane] = []
        func visit(_ range: Range<Int>, work: inout OverlayWork) throws -> Bool {
            for i in range {
                try work.spend()
                let plane = rings[ring][i], range = plane.range(in: box)
                if ring == 0, range.x >= 0 { continue }
                if range.y <= 0 { return false }
                if range.x < 0 || (strictInterior && range.x == 0) { crossing.append(plane) }
            }
            return true
        }
        if let tree = trees[ring] {
            var cursor = 0
            while cursor < tree.nodes.count {
                try work.spend()
                let node = tree.nodes[cursor]
                if let interval = tree.interval(node, box: box, epsilon: epsilon) {
                    if strictInterior ? interval.x > 0 : interval.x >= 0 { cursor = node.escape; continue }
                    if interval.y < 0 { return .outside }
                }
                if node.range.count <= 8 {
                    if try !visit(node.range, work: &work) { return .outside }
                    cursor = node.escape
                } else { cursor += 1 }
            }
        } else if try !visit(rings[ring].indices, work: &work) { return .outside }
        return crossing.isEmpty ? .inside : .crossing(crossing)
    }

    /// A broad region may discard only planes already proven irrelevant to its entire box.
    /// Children retain the original ordered predicates for every crossing plane.
    func region(for box: OverlayBounds, epsilon: Double, work: inout OverlayWork) throws -> Region {
        var classifications: [Classification] = []
        for ring in rings.indices {
            classifications.append(try bounds[ring].intersects(box)
                ? classify(ring, box: box, epsilon: epsilon, strictInterior: ring > 0, work: &work) : .outside)
        }
        return .init(bounds: box, rings: classifications)
    }

    private func classify(_ ring: Int, box: OverlayBounds, region: Region?, epsilon: Double,
                          work: inout OverlayWork) throws -> Classification {
        guard let region, box.lo.x >= region.bounds.lo.x, box.lo.y >= region.bounds.lo.y,
              box.hi.x <= region.bounds.hi.x, box.hi.y <= region.bounds.hi.y else {
            return try classify(ring, box: box, epsilon: epsilon, work: &work)
        }
        guard case .crossing(let planes) = region.rings[ring] else { return region.rings[ring] }
        var crossing: [Plane] = []
        for plane in planes {
            try work.spend()
            let range = plane.range(in: box)
            if ring == 0, range.x >= 0 { continue }
            if range.y <= 0 { return .outside }
            if range.x < 0 { crossing.append(plane) }
        }
        return crossing.isEmpty ? .inside : .crossing(crossing)
    }

    /// One classification pass replaces separate edge-touch and point-in-area traversals.
    /// Whole resident faces need neither fragment arrays nor an artificial tessellation.
    func intersection(of triangle: OverlayTriangle, region: Region? = nil, epsilon: Double, work: inout OverlayWork) throws -> Intersection {
        let box = triangle.bounds
        var result: [[OverlayVertex]]?
        switch try classify(0, box: box, region: region, epsilon: epsilon, work: &work) {
        case .outside: return .empty
        case .inside: break
        case .crossing(let planes):
            var exterior = triangle.vertices
            for plane in planes {
                exterior = try Self.clip(exterior, plane: plane, inside: true, epsilon: epsilon, work: &work)
                if exterior.count < 3 { return .empty }
            }
            result = [exterior]
        }
        for hole in rings.indices.dropFirst() where bounds[hole].intersects(box) {
            switch try classify(hole, box: box, region: region, epsilon: epsilon, work: &work) {
            case .outside: continue
            case .inside: return .empty
            case .crossing(let planes):
                var next: [[OverlayVertex]] = []
                for polygon in result ?? [triangle.vertices] {
                    var remaining = polygon
                    for plane in planes {
                        let split = try Self.split(remaining, plane: plane, epsilon: epsilon, work: &work)
                        if split.outside.count >= 3 { next.append(split.outside) }
                        remaining = split.inside
                        if remaining.count < 3 { break }
                    }
                }
                if next.isEmpty { return .empty }
                result = next
            }
        }
        return result.map(Intersection.clipped) ?? .whole
    }

    func fragments(of triangle: OverlayTriangle, epsilon: Double, work: inout OverlayWork) throws -> [[OverlayVertex]] {
        switch try intersection(of: triangle, epsilon: epsilon, work: &work) {
        case .empty: []
        case .whole: [triangle.vertices]
        case .clipped(let fragments): fragments
        }
    }

    /// Partition a hole boundary once. Both halves share the same intersection calculation;
    /// appending normalized vertices avoids a second allocation/copy for every fragment.
    private static func split(_ polygon: [OverlayVertex], plane: Plane, epsilon: Double,
                              work: inout OverlayWork) throws -> (inside: [OverlayVertex], outside: [OverlayVertex]) {
        guard let last = polygon.last else { return ([], []) }
        try work.spend(polygon.count)
        var minimum = Double.infinity, maximum = -Double.infinity
        for vertex in polygon {
            let side = plane.side(vertex)
            minimum = min(minimum, side); maximum = max(maximum, side)
        }
        if minimum >= 0 { return (polygon, maximum <= 0 ? polygon : []) }
        if maximum <= 0 { return ([], polygon) }
        var inside: [OverlayVertex] = [], outside: [OverlayVertex] = []
        inside.reserveCapacity(polygon.count + 1); outside.reserveCapacity(polygon.count + 1)
        var previous = last, previousSide = plane.side(last)
        for current in polygon {
            let side = plane.side(current)
            let entersInside = (side >= 0) != (previousSide >= 0)
            let entersOutside = (side <= 0) != (previousSide <= 0)
            if entersInside || entersOutside {
                let cut = previous.interpolated(to: current, at: previousSide / (previousSide - side))
                if entersInside { append(cut, to: &inside, epsilon: epsilon) }
                if entersOutside { append(cut, to: &outside, epsilon: epsilon) }
            }
            if side >= 0 { append(current, to: &inside, epsilon: epsilon) }
            if side <= 0 { append(current, to: &outside, epsilon: epsilon) }
            previous = current; previousSide = side
        }
        close(&inside, epsilon: epsilon); close(&outside, epsilon: epsilon)
        return (inside, outside)
    }

    private static func append(_ vertex: OverlayVertex, to polygon: inout [OverlayVertex], epsilon: Double) {
        if polygon.last.map({ simd_distance($0.point, vertex.point) > epsilon }) ?? true { polygon.append(vertex) }
    }
    private static func close(_ polygon: inout [OverlayVertex], epsilon: Double) {
        while polygon.count > 1, simd_distance(polygon[0].point, polygon[polygon.count - 1].point) <= epsilon { polygon.removeLast() }
    }

    private static func clip(_ polygon: [OverlayVertex], plane: Plane, inside: Bool,
                             epsilon: Double, work: inout OverlayWork) throws -> [OverlayVertex] {
        guard let last = polygon.last else { return [] }
        try work.spend(polygon.count)
        let sign = inside ? 1.0 : -1.0
        var minimum = Double.infinity, maximum = -Double.infinity
        for vertex in polygon {
            let side = sign * plane.side(vertex)
            minimum = min(minimum, side); maximum = max(maximum, side)
        }
        if minimum >= 0 { return polygon }
        if maximum <= 0 { return [] }
        var result: [OverlayVertex] = []
        result.reserveCapacity(polygon.count + 1)
        var previous = last, previousSide = sign * plane.side(last)
        for current in polygon {
            let side = sign * plane.side(current)
            if (side >= 0) != (previousSide >= 0) {
                append(previous.interpolated(to: current, at: previousSide / (previousSide - side)), to: &result, epsilon: epsilon)
            }
            if side >= 0 { append(current, to: &result, epsilon: epsilon) }
            previous = current; previousSide = side
        }
        close(&result, epsilon: epsilon)
        return result
    }
}
