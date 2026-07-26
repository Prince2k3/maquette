import Foundation
import simd

/// A `DioramaBoundary` raised into a vertical prism, expressed as convex pieces so mesh geometry
/// can be clipped against it exactly.
///
/// Sutherland-Hodgman needs a convex clip region. Every built-in shape is convex and becomes a
/// single piece, so the common case costs nothing extra; a concave custom outline is split into
/// convex pieces whose union is the original, which keeps the clip exact rather than notching the
/// geometry at reflex corners.
struct BoundaryPrism {
    /// A convex region of the outline, with edges wound so a point inside lies to the right of
    /// every edge direction.
    struct Piece {
        let edges: [(a: SIMD2<Float>, b: SIMD2<Float>)]
        let lowerBound: SIMD2<Float>
        let upperBound: SIMD2<Float>

        init(vertices: [SIMD2<Float>]) {
            var edges: [(a: SIMD2<Float>, b: SIMD2<Float>)] = []
            edges.reserveCapacity(vertices.count)
            for index in vertices.indices {
                edges.append((vertices[index], vertices[(index + 1) % vertices.count]))
            }
            self.edges = edges

            var low = vertices[0]
            var high = vertices[0]
            for vertex in vertices.dropFirst() {
                low = simd_min(low, vertex)
                high = simd_max(high, vertex)
            }
            self.lowerBound = low
            self.upperBound = high
        }
    }

    let pieces: [Piece]
    let lowerBound: SIMD2<Float>
    let upperBound: SIMD2<Float>
    /// The outline this prism was raised from, for whole-triangle containment tests.
    let boundary: DioramaBoundary
    /// Distance along the outline to the start of each edge, for texturing the cut wall.
    let cumulativeEdgeLengths: [Float]
    /// Total length of the outline.
    let perimeter: Float

    /// Centre of the inscribed and circumscribed circles used to answer containment cheaply.
    private let centroid: SIMD2<Float>
    /// Radius² of the largest circle about `centroid` that is wholly inside the outline.
    private let innerRadiusSquared: Float
    /// Radius² of the smallest circle about `centroid` that encloses the outline.
    private let outerRadiusSquared: Float

    /// Builds a prism from an outline, scaled into the space the geometry lives in.
    ///
    /// - Parameters:
    ///   - boundary: The outline, in diorama meters.
    ///   - scale: Divides the outline into the geometry's space. 3D Tiles geometry is in
    ///     real-world meters while the boundary is in diorama meters, and `Tiles3DEntity` carries
    ///     the conversion as an entity scale, so the outline has to be scaled up to match.
    init(boundary: DioramaBoundary, scale: Float) {
        let scaled = scale > 0 ? boundary.vertices.map { $0 / scale } : boundary.vertices
        let scaledBoundary = DioramaBoundary(vertices: scaled)
        self.boundary = scaledBoundary

        // Convex outlines clip exactly as a single piece; only concave ones need splitting.
        if Self.isConvex(scaled) {
            self.pieces = [Piece(vertices: scaled)]
        } else {
            let triangles = PolygonClipping.triangulate(scaled, minimumArea: 0)
            self.pieces = triangles.map { triangle in
                Piece(vertices: [scaled[triangle.0], scaled[triangle.1], scaled[triangle.2]])
            }
        }

        var low = scaled[0]
        var high = scaled[0]
        for vertex in scaled.dropFirst() {
            low = simd_min(low, vertex)
            high = simd_max(high, vertex)
        }
        self.lowerBound = low
        self.upperBound = high

        var lengths: [Float] = []
        lengths.reserveCapacity(scaledBoundary.edgeCount)
        var running: Float = 0
        for index in 0..<scaledBoundary.edgeCount {
            lengths.append(running)
            let (a, b) = scaledBoundary.edge(index)
            running += simd_distance(a, b)
        }
        self.cumulativeEdgeLengths = lengths
        self.perimeter = running

        // Containment is asked once per triangle corner of every streamed tile, so a crossing-number
        // walk over the outline — 128 vertices for a circle — dominates the clip. Two circles about
        // the centroid answer almost every query in constant time instead: inside the inscribed one
        // is certainly inside, outside the circumscribed one is certainly outside, and only the
        // annulus between them needs the exact test. For a circular outline, which is the default,
        // the two radii differ by cos(π/128) and virtually nothing reaches the fallback.
        let centre = scaled.reduce(SIMD2<Float>.zero, +) / Float(max(scaled.count, 1))
        self.centroid = centre

        var farthest: Float = 0
        for vertex in scaled {
            farthest = max(farthest, simd_length_squared(vertex - centre))
        }
        self.outerRadiusSquared = farthest

        // Valid only when the centroid is itself inside: the disc reaching the nearest boundary
        // point crosses no edge, so a centre inside puts all of it inside. A concave outline can
        // put its centroid outside, and then there is no inscribed circle to lean on.
        if scaledBoundary.contains(centre) {
            var nearest = Float.greatestFiniteMagnitude
            for index in 0..<scaledBoundary.edgeCount {
                let (a, b) = scaledBoundary.edge(index)
                nearest = min(nearest, Self.distanceSquaredToSegment(centre, a, b))
            }
            self.innerRadiusSquared = nearest
        } else {
            self.innerRadiusSquared = 0
        }
    }

    /// Squared distance from a point to a line segment.
    private static func distanceSquaredToSegment(
        _ point: SIMD2<Float>,
        _ a: SIMD2<Float>,
        _ b: SIMD2<Float>
    ) -> Float {
        let span = b - a
        let lengthSquared = simd_length_squared(span)
        guard lengthSquared > 0 else { return simd_length_squared(point - a) }
        let t = simd_clamp(simd_dot(point - a, span) / lengthSquared, 0, 1)
        return simd_length_squared(point - (a + span * t))
    }

    /// Whether a horizontal position lies inside the outline.
    func contains(_ point: SIMD2<Float>) -> Bool {
        let distanceSquared = simd_length_squared(point - centroid)
        // Strictly inside the inscribed circle, because the circle touches the outline: a point at
        // exactly that radius is *on* the boundary, where containment is ambiguous and only the
        // exact test's answer will do.
        if distanceSquared < innerRadiusSquared { return true }
        if distanceSquared > outerRadiusSquared { return false }
        return boundary.contains(point)
    }

    // MARK: - Cut Edges

    /// How close to the outline a segment must lie to count as sitting on it.
    ///
    /// Scaled off the outline's own size rather than fixed, because this prism lives in the
    /// geometry's space: a kilometre-wide diorama and a hundred-metre one need different absolute
    /// slack for the same relative precision. Well above single-precision error at these magnitudes
    /// and well below the spacing between distinct boundary edges, so it neither misses a cut nor
    /// mistakes one edge for another.
    var cutEdgeTolerance: Float {
        let extent = upperBound - lowerBound
        return max(extent.x, extent.y) * 1e-4
    }

    /// The boundary edge a segment lies along, if it lies along one at all.
    ///
    /// Both endpoints *and* the midpoint have to be near the same edge. Testing the endpoints alone
    /// would accept a chord — a segment whose ends happen to touch the outline while the segment
    /// itself cuts across the interior — and walling a chord puts a wall through the middle of the
    /// model. A clipped triangle produces those routinely: two of its corners can land on the
    /// outline while the edge between them stays inside.
    func boundaryEdge(along a: SIMD2<Float>, _ b: SIMD2<Float>) -> Int? {
        let tolerance = cutEdgeTolerance
        guard simd_distance(a, b) > tolerance else { return nil }

        let midpoint = (a + b) / 2
        var best: Int?
        var bestDistance = tolerance
        for index in 0..<boundary.edgeCount {
            let distance = boundary.distance(from: midpoint, toEdge: index)
            guard distance <= bestDistance else { continue }
            guard boundary.distance(from: a, toEdge: index) <= tolerance,
                  boundary.distance(from: b, toEdge: index) <= tolerance else { continue }
            bestDistance = distance
            best = index
        }
        return best
    }

    /// Where a point sitting on a known boundary edge falls along the outline, normalized to 0...1.
    func perimeterPosition(of point: SIMD2<Float>, onEdge index: Int) -> Float {
        guard perimeter > 0, cumulativeEdgeLengths.indices.contains(index) else { return 0 }
        let (start, end) = boundary.edge(index)
        let direction = end - start
        let lengthSquared = simd_length_squared(direction)
        let along: Float = lengthSquared > 0
            ? min(max(simd_dot(point - start, direction) / lengthSquared, 0), 1) * sqrt(lengthSquared)
            : 0
        return ((cumulativeEdgeLengths[index] + along) / perimeter).clampedToUnitRange
    }

    /// Pieces whose bounds overlap the given horizontal range.
    func pieces(overlapping lower: SIMD2<Float>, _ upper: SIMD2<Float>) -> [Piece] {
        guard pieces.count > 1 else { return pieces }
        return pieces.filter { piece in
            piece.upperBound.x >= lower.x && piece.lowerBound.x <= upper.x
                && piece.upperBound.y >= lower.y && piece.lowerBound.y <= upper.y
        }
    }

    /// A polygon is convex when every turn goes the same way.
    static func isConvex(_ vertices: [SIMD2<Float>]) -> Bool {
        guard vertices.count > 3 else { return true }

        var sign: Float = 0
        for index in vertices.indices {
            let previous = vertices[index]
            let current = vertices[(index + 1) % vertices.count]
            let next = vertices[(index + 2) % vertices.count]
            let turn = PolygonClipping.cross(current - previous, next - current)
            if abs(turn) < .ulpOfOne { continue }
            if sign == 0 {
                sign = turn
            } else if turn * sign < 0 {
                return false
            }
        }
        return true
    }
}
