import simd

/// A triangle intersected with a triangle/rectangle has at most six/seven corners. Fixed storage avoids heap allocation in the
/// raster draper's inner loop; the general polygon/photogrammetry clipper remains unchanged.
enum OverlayTriangleIntersection {
    struct Polygon {
        private var v0 = OverlayVertex(point: .zero)
        private var v1 = OverlayVertex(point: .zero)
        private var v2 = OverlayVertex(point: .zero)
        private var v3 = OverlayVertex(point: .zero)
        private var v4 = OverlayVertex(point: .zero)
        private var v5 = OverlayVertex(point: .zero)
        private var v6 = OverlayVertex(point: .zero)
        private var v7 = OverlayVertex(point: .zero)
        var count = 0
        subscript(_ index: Int) -> OverlayVertex {
            @inline(__always) get {
                switch index {
                case 0: v0
                case 1: v1
                case 2: v2
                case 3: v3
                case 4: v4
                case 5: v5
                case 6: v6
                default: v7
                }
            }
            @inline(__always) set {
                switch index {
                case 0: v0 = newValue
                case 1: v1 = newValue
                case 2: v2 = newValue
                case 3: v3 = newValue
                case 4: v4 = newValue
                case 5: v5 = newValue
                case 6: v6 = newValue
                default: v7 = newValue
                }
            }
        }
        mutating func append(_ vertex: OverlayVertex, epsilon: Double) {
            if count > 0, simd_distance(self[count - 1].point, vertex.point) <= epsilon { return }
            self[count] = vertex
            count += 1
        }
    }

    static func clip(_ source: OverlayTriangle, a: SIMD2<Double>, b: SIMD2<Double>, c: SIMD2<Double>, d: SIMD2<Double>? = nil,
                     epsilon: Double, work: inout OverlayWork) throws -> Polygon {
        let area = OverlayMath.cross(b - a, c - a)
        guard abs(area) > epsilon * epsilon else { return Polygon() }
        let sign = area > 0 ? 1.0 : -1.0
        var polygon = Polygon()
        polygon.append(source.a, epsilon: epsilon)
        polygon.append(source.b, epsilon: epsilon)
        polygon.append(source.c, epsilon: epsilon)
        let edgeCount = d == nil ? 3 : 4
        for edge in 0..<edgeCount {
            guard polygon.count >= 3 else { return Polygon() }
            let origin = edge == 0 ? a : edge == 1 ? b : edge == 2 ? c : d!
            let direction = (edge == 0 ? b : edge == 1 ? c : edge == 2 ? (d ?? a) : a) - origin
            // Dense ribbons are much smaller than a terrain face. Most clip edges leave the
            // entire fragment untouched; classify once instead of copying its fixed storage.
            var sides = SIMD8<Double>.zero
            var allInside = true, allOutside = true
            for i in 0..<polygon.count {
                try work.spend()
                let side = sign * OverlayMath.cross(direction, polygon[i].point - origin)
                sides[i] = side
                allInside = allInside && side >= 0
                allOutside = allOutside && side < 0
            }
            if allOutside { return Polygon() }
            if allInside {
                while polygon.count > 1, simd_distance(polygon[0].point, polygon[polygon.count - 1].point) <= epsilon {
                    polygon.count -= 1
                }
                continue
            }
            var output = Polygon()
            var previous = polygon[polygon.count - 1]
            var previousSide = sides[polygon.count - 1]
            for i in 0..<polygon.count {
                let current = polygon[i]
                let side = sides[i]
                if (side >= 0) != (previousSide >= 0) {
                    output.append(previous.interpolated(to: current, at: previousSide / (previousSide - side)), epsilon: epsilon)
                }
                if side >= 0 { output.append(current, epsilon: epsilon) }
                previous = current; previousSide = side
            }
            while output.count > 1, simd_distance(output[0].point, output[output.count - 1].point) <= epsilon {
                output.count -= 1
            }
            polygon = output
        }
        return polygon
    }
}
