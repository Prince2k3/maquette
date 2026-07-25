import Foundation
import simd

/// A closed polygonal outline in the diorama's horizontal (X/Z) plane that defines where the
/// terrain chunk is cut out of the world.
///
/// Every `DioramaShape` resolves to a boundary. Mesh generation clips the terrain grid against it,
/// so the chunk's silhouette is exact rather than approximated by snapping grid vertices — which is
/// what lets the cut edge read as a clean slice through the earth.
///
/// ## Winding
///
/// Vertices are normalized on construction so that fan-triangulating any sub-polygon in vertex
/// order produces upward-facing (+Y) normals. Callers can rely on this when building the top
/// surface, and on `outwardNormal(forEdgeFrom:to:)` when building walls.
public struct DioramaBoundary: Sendable {
    /// Boundary vertices as (x, z) pairs, forming a closed loop. The closing edge from the last
    /// vertex back to the first is implicit.
    public let vertices: [SIMD2<Float>]

    /// Axis-aligned bounding box size of the boundary: X width and Z depth.
    public let extent: SIMD2<Float>

    /// Axis-aligned bounding box minimum corner.
    public let minCorner: SIMD2<Float>

    /// Creates a boundary from an explicit closed loop of (x, z) points.
    ///
    /// The loop is normalized to the winding described above; duplicate consecutive points and a
    /// repeated closing point are removed.
    ///
    /// - Parameter vertices: At least three points describing a closed loop. The loop should not
    ///   repeat its first point at the end, though a repeated point is tolerated.
    public init(vertices: [SIMD2<Float>]) {
        var cleaned: [SIMD2<Float>] = []
        for vertex in vertices {
            if let last = cleaned.last, simd_distance(last, vertex) < Self.weldEpsilon { continue }
            cleaned.append(vertex)
        }
        if cleaned.count > 1,
           let first = cleaned.first,
           let last = cleaned.last,
           simd_distance(first, last) < Self.weldEpsilon {
            cleaned.removeLast()
        }

        precondition(cleaned.count >= 3, "A diorama boundary needs at least three distinct vertices")

        // Normalize winding so fan triangulation yields +Y normals. In the (x, z) plane treated as
        // standard 2D, that corresponds to a negative signed area.
        if Self.signedArea(of: cleaned) > 0 {
            cleaned.reverse()
        }
        self.vertices = cleaned

        var lo = cleaned[0]
        var hi = cleaned[0]
        for vertex in cleaned.dropFirst() {
            lo = simd_min(lo, vertex)
            hi = simd_max(hi, vertex)
        }
        self.minCorner = lo
        self.extent = hi - lo
    }

    /// Builds the boundary for a shape sized to fill the given horizontal extent.
    ///
    /// - Parameters:
    ///   - shape: The diorama shape to realize.
    ///   - extent: Available horizontal extent in diorama meters (X width, Z depth).
    ///   - segmentsPerCurve: Number of straight segments used to approximate curved edges.
    public static func make(
        shape: DioramaShape,
        extent: SIMD2<Float>,
        segmentsPerCurve: Int = 128
    ) -> DioramaBoundary {
        switch shape {
        case .circular:
            let radius = min(extent.x, extent.y) / 2
            return DioramaBoundary(vertices: circlePoints(radius: radius, segments: segmentsPerCurve))

        case .rectangular(let width, let depth):
            let halfWidth = width / 2
            let halfDepth = depth / 2
            return DioramaBoundary(vertices: [
                SIMD2(-halfWidth, -halfDepth),
                SIMD2(halfWidth, -halfDepth),
                SIMD2(halfWidth, halfDepth),
                SIMD2(-halfWidth, halfDepth),
            ])

        case .roundedRectangular(let width, let depth, let cornerRadius):
            return DioramaBoundary(vertices: roundedRectanglePoints(
                width: width,
                depth: depth,
                cornerRadius: cornerRadius,
                segmentsPerCorner: max(2, segmentsPerCurve / 8)
            ))

        case .polygonal(let sides, let rotation):
            let radius = min(extent.x, extent.y) / 2
            return DioramaBoundary(vertices: regularPolygonPoints(
                radius: radius,
                sides: max(3, sides),
                rotation: rotation
            ))

        case .custom(let points):
            return DioramaBoundary(vertices: points)
        }
    }

    /// Returns whether a point lies inside the boundary, using a crossing-number test.
    ///
    /// Correct for both convex and concave outlines.
    public func contains(_ point: SIMD2<Float>) -> Bool {
        var inside = false
        var j = vertices.count - 1
        for i in 0..<vertices.count {
            let a = vertices[i]
            let b = vertices[j]
            if (a.y > point.y) != (b.y > point.y) {
                let t = (point.y - a.y) / (b.y - a.y)
                if point.x < a.x + t * (b.x - a.x) {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    /// Total length of the boundary loop in diorama meters.
    public var perimeter: Float {
        var total: Float = 0
        for i in 0..<vertices.count {
            total += simd_distance(vertices[i], vertices[(i + 1) % vertices.count])
        }
        return total
    }

    /// Returns the outward-facing horizontal normal for a boundary-aligned edge.
    ///
    /// Given the normalized winding, the exterior lies to the left of the edge direction in the
    /// (x, z) plane, which makes `(-dz, dx)` point away from the chunk.
    public static func outwardNormal(forEdgeFrom a: SIMD2<Float>, to b: SIMD2<Float>) -> SIMD3<Float> {
        let direction = b - a
        let normal = SIMD3<Float>(-direction.y, 0, direction.x)
        let length = simd_length(normal)
        return length > 0 ? normal / length : SIMD3<Float>(0, 0, 1)
    }

    // MARK: - Segment Lookup

    /// Bounding box of the boundary edge starting at `index`.
    func edgeBounds(_ index: Int) -> (lo: SIMD2<Float>, hi: SIMD2<Float>) {
        let a = vertices[index]
        let b = vertices[(index + 1) % vertices.count]
        return (simd_min(a, b), simd_max(a, b))
    }

    /// Endpoints of the boundary edge starting at `index`.
    func edge(_ index: Int) -> (a: SIMD2<Float>, b: SIMD2<Float>) {
        (vertices[index], vertices[(index + 1) % vertices.count])
    }

    /// Number of edges in the loop.
    var edgeCount: Int { vertices.count }

    /// Returns the distance from a point to the boundary edge starting at `index`.
    func distance(from point: SIMD2<Float>, toEdge index: Int) -> Float {
        let (a, b) = edge(index)
        let direction = b - a
        let lengthSquared = simd_length_squared(direction)
        guard lengthSquared > 0 else { return simd_distance(point, a) }
        let t = min(max(simd_dot(point - a, direction) / lengthSquared, 0), 1)
        return simd_distance(point, a + direction * t)
    }

    // MARK: - Shape Construction

    private static let weldEpsilon: Float = 1e-7

    private static func signedArea(of points: [SIMD2<Float>]) -> Float {
        var total: Float = 0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            total += a.x * b.y - b.x * a.y
        }
        return total / 2
    }

    private static func circlePoints(radius: Float, segments: Int) -> [SIMD2<Float>] {
        (0..<segments).map { i in
            let angle = Float(i) / Float(segments) * 2 * .pi
            return SIMD2(radius * cos(angle), radius * sin(angle))
        }
    }

    private static func regularPolygonPoints(radius: Float, sides: Int, rotation: Float) -> [SIMD2<Float>] {
        (0..<sides).map { i in
            let angle = Float(i) / Float(sides) * 2 * .pi + rotation
            return SIMD2(radius * cos(angle), radius * sin(angle))
        }
    }

    private static func roundedRectanglePoints(
        width: Float,
        depth: Float,
        cornerRadius: Float,
        segmentsPerCorner: Int
    ) -> [SIMD2<Float>] {
        let halfWidth = width / 2
        let halfDepth = depth / 2
        let radius = min(cornerRadius, min(halfWidth, halfDepth))

        guard radius > 0 else {
            return [
                SIMD2(-halfWidth, -halfDepth),
                SIMD2(halfWidth, -halfDepth),
                SIMD2(halfWidth, halfDepth),
                SIMD2(-halfWidth, halfDepth),
            ]
        }

        // Corner centers in counter-clockwise order starting from +X/+Z.
        let centers: [SIMD2<Float>] = [
            SIMD2(halfWidth - radius, halfDepth - radius),
            SIMD2(-halfWidth + radius, halfDepth - radius),
            SIMD2(-halfWidth + radius, -halfDepth + radius),
            SIMD2(halfWidth - radius, -halfDepth + radius),
        ]

        var points: [SIMD2<Float>] = []
        for (index, center) in centers.enumerated() {
            let startAngle = Float(index) * .pi / 2
            for step in 0...segmentsPerCorner {
                let angle = startAngle + Float(step) / Float(segmentsPerCorner) * (.pi / 2)
                points.append(center + SIMD2(radius * cos(angle), radius * sin(angle)))
            }
        }
        return points
    }
}
