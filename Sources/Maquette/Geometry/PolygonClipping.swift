import Foundation
import simd

/// Two-dimensional polygon operations shared by the terrain and photorealistic pipelines.
///
/// Both pipelines cut geometry to a `DioramaBoundary`, and both hit the same trap: Sutherland-
/// Hodgman clipping is exact only when the **clip region** is convex, while a chunk boundary may be
/// concave. The way out in both cases is to make the small convex thing the clip region and the
/// boundary the subject — a grid cell for terrain, a mesh triangle for 3D Tiles.
enum PolygonClipping {
    /// Clips a polygon against a convex region described by its edges.
    ///
    /// Exact for any subject polygon, convex or concave, provided the clip region is convex.
    ///
    /// Edges must be wound to `DioramaBoundary`'s convention, where a point is inside when it lies
    /// to the right of every edge direction.
    static func clip(
        polygon: [SIMD2<Float>],
        against edges: [(SIMD2<Float>, SIMD2<Float>)]
    ) -> [SIMD2<Float>] {
        var output = polygon

        for (a, b) in edges {
            guard output.count >= 3 else { return [] }
            let direction = b - a

            // Positive means outside, given the boundary's normalized winding.
            func side(_ p: SIMD2<Float>) -> Float {
                direction.x * (p.y - a.y) - direction.y * (p.x - a.x)
            }

            let input = output
            output = []
            output.reserveCapacity(input.count + 1)

            var previous = input[input.count - 1]
            var previousSide = side(previous)

            for current in input {
                let currentSide = side(current)
                let currentInside = currentSide <= 0
                let previousInside = previousSide <= 0

                if currentInside {
                    if !previousInside {
                        output.append(intersection(previous, current, previousSide, currentSide))
                    }
                    output.append(current)
                } else if previousInside {
                    output.append(intersection(previous, current, previousSide, currentSide))
                }

                previous = current
                previousSide = currentSide
            }
        }

        return output.count >= 3 ? output : []
    }

    /// Triangulates a simple polygon by ear clipping, returning index triples that preserve the
    /// polygon's winding.
    ///
    /// Handles concave polygons, which a fan from one vertex would triangulate across the notch.
    /// Triangles below `minimumArea` are dropped rather than emitted as slivers.
    static func triangulate(
        _ polygon: [SIMD2<Float>],
        minimumArea: Float
    ) -> [(Int, Int, Int)] {
        guard polygon.count >= 3 else { return [] }
        if polygon.count == 3 {
            return signedArea(polygon) != 0 && area(polygon) > minimumArea ? [(0, 1, 2)] : []
        }

        // A vertex is convex when its turn matches the polygon's own orientation.
        let orientation = signedArea(polygon)
        guard orientation != 0 else { return [] }

        var remaining = Array(polygon.indices)
        var triangles: [(Int, Int, Int)] = []
        triangles.reserveCapacity(polygon.count - 2)

        func isEar(at position: Int) -> Bool {
            let count = remaining.count
            let previousIndex = remaining[(position + count - 1) % count]
            let currentIndex = remaining[position]
            let nextIndex = remaining[(position + 1) % count]

            let previous = polygon[previousIndex]
            let current = polygon[currentIndex]
            let next = polygon[nextIndex]

            let turn = cross(current - previous, next - current)
            guard turn * orientation > 0 else { return false }

            // No other remaining vertex may fall inside the candidate ear.
            for index in remaining
            where index != previousIndex && index != currentIndex && index != nextIndex {
                if pointInTriangle(polygon[index], previous, current, next) { return false }
            }
            return true
        }

        while remaining.count > 3 {
            var clippedEar = false

            for position in remaining.indices where isEar(at: position) {
                let count = remaining.count
                let previousIndex = remaining[(position + count - 1) % count]
                let currentIndex = remaining[position]
                let nextIndex = remaining[(position + 1) % count]

                triangles.append((previousIndex, currentIndex, nextIndex))
                remaining.remove(at: position)
                clippedEar = true
                break
            }

            // Numerically degenerate input can leave no valid ear; stop rather than spin.
            guard clippedEar else { break }
        }

        if remaining.count == 3 {
            triangles.append((remaining[0], remaining[1], remaining[2]))
        }

        return triangles.filter { triangle in
            let a = polygon[triangle.0]
            let b = polygon[triangle.1]
            let c = polygon[triangle.2]
            return abs(cross(b - a, c - a)) / 2 > minimumArea
        }
    }

    /// Removes consecutive coincident points, including across the closing edge.
    ///
    /// Clipping against an edge that lies along the subject produces duplicate points, which would
    /// otherwise become zero-area triangles.
    static func removingDuplicatePoints(
        _ polygon: [SIMD2<Float>],
        weldDistance: Float
    ) -> [SIMD2<Float>] {
        guard polygon.count >= 2 else { return polygon }

        var result: [SIMD2<Float>] = []
        result.reserveCapacity(polygon.count)
        for point in polygon {
            if let last = result.last, simd_distance(last, point) <= weldDistance { continue }
            result.append(point)
        }
        while result.count >= 2, simd_distance(result[0], result[result.count - 1]) <= weldDistance {
            result.removeLast()
        }
        return result
    }

    /// Unsigned area of a simple polygon.
    static func area(_ points: [SIMD2<Float>]) -> Float {
        guard points.count >= 3 else { return 0 }
        return abs(signedArea(points))
    }

    /// Signed area of a simple polygon. Negative matches `DioramaBoundary`'s winding.
    static func signedArea(_ polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count >= 3 else { return 0 }
        var total: Float = 0
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            total += a.x * b.y - b.x * a.y
        }
        return total / 2
    }

    /// Two-dimensional cross product of the (x, z) plane treated as standard 2D.
    @inline(__always)
    static func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float {
        u.x * v.y - u.y * v.x
    }

    /// Orientation-independent point-in-triangle test, inclusive of the edges.
    static func pointInTriangle(
        _ point: SIMD2<Float>,
        _ a: SIMD2<Float>,
        _ b: SIMD2<Float>,
        _ c: SIMD2<Float>
    ) -> Bool {
        let d1 = cross(b - a, point - a)
        let d2 = cross(c - b, point - b)
        let d3 = cross(a - c, point - c)
        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNegative && hasPositive)
    }

    private static func intersection(
        _ from: SIMD2<Float>,
        _ to: SIMD2<Float>,
        _ fromSide: Float,
        _ toSide: Float
    ) -> SIMD2<Float> {
        let denominator = fromSide - toSide
        guard abs(denominator) > .ulpOfOne else { return from }
        let t = min(max(fromSide / denominator, 0), 1)
        return from + (to - from) * t
    }
}
