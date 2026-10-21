import simd

/// Validated convex rings can cut a terrain face directly. This avoids the artificial slab
/// boundaries of the general tessellation; variable attributes and concavities use that path.
struct OverlayConvexArea {
    private struct Plane {
        var origin: SIMD2<Double>
        var normal: SIMD2<Double>
        func side(_ vertex: OverlayVertex) -> Double { simd_dot(normal, vertex.point - origin) }
        func range(in bounds: OverlayBounds) -> SIMD2<Double> {
            let low = SIMD2(normal.x >= 0 ? bounds.lo.x : bounds.hi.x, normal.y >= 0 ? bounds.lo.y : bounds.hi.y)
            let high = SIMD2(normal.x >= 0 ? bounds.hi.x : bounds.lo.x, normal.y >= 0 ? bounds.hi.y : bounds.lo.y)
            return .init(simd_dot(normal, low - origin), simd_dot(normal, high - origin))
        }
    }
    private let rings: [[Plane]]
    private let bounds: [OverlayBounds]

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
        bounds = input.map { OverlayBounds($0.map(\.point)) }
    }

    func fragments(of triangle: OverlayTriangle, epsilon: Double, work: inout OverlayWork) throws -> [[OverlayVertex]] {
        let box = triangle.bounds
        var exterior = triangle.vertices
        for plane in rings[0] {
            try work.spend()
            let range = plane.range(in: box)
            if range.x >= 0 { continue }
            if range.y <= 0 { return [] }
            exterior = try Self.clip(exterior, plane: plane, inside: true, epsilon: epsilon, work: &work)
            if exterior.count < 3 { return [] }
        }
        var result = [exterior]
        for hole in rings.indices.dropFirst() where bounds[hole].intersects(triangle.bounds) {
            // Box support corners safely eliminate planes before touching fragment arrays.
            var crossing: [Plane] = []
            var disjoint = false
            for plane in rings[hole] {
                try work.spend()
                let range = plane.range(in: box)
                if range.y <= 0 { disjoint = true; break }
                if range.x < 0 { crossing.append(plane) }
            }
            if disjoint { continue }
            if crossing.isEmpty { return [] }
            var next: [[OverlayVertex]] = []
            for polygon in result {
                var remaining = polygon
                for plane in crossing {
                    let split = try Self.split(remaining, plane: plane, epsilon: epsilon, work: &work)
                    if split.outside.count >= 3 { next.append(split.outside) }
                    remaining = split.inside
                    if remaining.count < 3 { break }
                }
            }
            result = next
            if result.isEmpty { break }
        }
        return result
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
