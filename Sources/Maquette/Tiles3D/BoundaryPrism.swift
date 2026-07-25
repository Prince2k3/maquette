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
    }

    /// Whether a horizontal position lies inside the outline.
    func contains(_ point: SIMD2<Float>) -> Bool {
        boundary.contains(point)
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
