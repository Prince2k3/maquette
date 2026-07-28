import Foundation
import simd

/// Builds the ink effect's drawn lines.
///
/// Lines are square-section tubes rather than the flat ribbons the hologram uses, and the difference
/// is not cosmetic. A ribbon lies in the horizontal plane, which is fine for a contour drawn across
/// ground that is being looked down at — but the ink effect's most important line is the chunk's
/// own rim, seen edge-on from any low angle, and a flat ribbon there thins to nothing exactly when
/// the silhouette matters most. A tube presents the same width from every direction.
///
/// The trade is that a tube's width is in diorama meters, so it scales with the model rather than
/// holding a constant weight on screen the way a drawn line does. Holding screen-space width would
/// need either a vertex shader — unavailable on visionOS without a Reality Composer Pro asset this
/// package deliberately does not ship — or a rebuild on every camera move.
enum InkGeometry {
    /// Draws each segment as a square-section tube.
    ///
    /// - Parameters:
    ///   - segments: The lines to draw, in the chunk's own space.
    ///   - radius: Half the tube's width, in diorama meters.
    ///   - mesh: Accumulator, so every line in one layer shares a single draw.
    static func addTubes(
        _ segments: [ContourExtractor.Segment],
        radius: Float,
        into mesh: inout IndexedMesh
    ) {
        guard radius > 0, !segments.isEmpty else { return }
        mesh.reserve(
            vertices: mesh.vertices.count + segments.count * 8,
            indices: mesh.indices.count + segments.count * 36
        )

        for segment in segments {
            let delta = segment.b - segment.a
            let length = simd_length(delta)
            guard length > 1e-7 else { continue }
            let direction = delta / length

            // Any pair of axes across the segment will do — the cross-section is square and the
            // material is unlit, so nothing downstream can tell which way round it was built. The
            // reference axis is swapped when the segment is near-vertical, which is not a corner
            // case here: the tubes down a chunk's corners are exactly that.
            let reference: SIMD3<Float> = abs(direction.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            let u = simd_normalize(simd_cross(direction, reference)) * radius
            let v = simd_normalize(simd_cross(direction, u)) * radius

            // Each end is pushed out by the tube's own radius so consecutive segments overlap into
            // their shared corner. Mitring the joint properly would first mean walking the segments
            // into paths, and at these widths the overlap is indistinguishable from a mitre.
            let overhang = direction * radius
            let start = segment.a - overhang
            let end = segment.b + overhang

            let corners = [u + v, u - v, -u - v, -u + v]
            var base: UInt32 = 0
            for (offset, corner) in corners.enumerated() {
                let normal = simd_normalize(corner)
                let index = mesh.append(position: start + corner, normal: normal, uv: .zero)
                if offset == 0 { base = index }
                mesh.append(position: end + corner, normal: normal, uv: .zero)
            }

            // Four sides, wound consistently around the tube, plus a cap at each end so a line that
            // stops in the open — the end of a crease, or a path's last segment — is not hollow.
            for side in 0..<4 {
                let near = base + UInt32(side) * 2
                let far = base + UInt32((side + 1) % 4) * 2
                mesh.appendTriangle(near, near + 1, far)
                mesh.appendTriangle(far, near + 1, far + 1)
            }
            mesh.appendTriangle(base, base + 4, base + 2)
            mesh.appendTriangle(base, base + 6, base + 4)
            mesh.appendTriangle(base + 1, base + 3, base + 5)
            mesh.appendTriangle(base + 1, base + 5, base + 7)
        }
    }

    /// Which vertices of an outline turn sharply enough to read as corners.
    ///
    /// The chunk's earth block gets a vertical ink line down each of these, and only these. Inking
    /// every boundary vertex would be right for a square and badly wrong for a circle, whose outline
    /// is a hundred-odd short segments turning about three degrees each — the block would come out a
    /// solid drum of ink rather than a cylinder, which has no vertical edges at all.
    ///
    /// - Parameters:
    ///   - outline: The chunk's boundary, in the horizontal plane.
    ///   - minimumAngle: How sharply the outline must turn, in radians, for a vertex to count.
    static func cornerIndices(of outline: [SIMD2<Float>], minimumAngle: Float) -> [Int] {
        guard outline.count >= 3, minimumAngle > 0 else { return [] }
        let threshold = cos(minimumAngle)

        return outline.indices.filter { index in
            let previous = outline[(index + outline.count - 1) % outline.count]
            let vertex = outline[index]
            let next = outline[(index + 1) % outline.count]

            let incoming = vertex - previous
            let outgoing = next - vertex
            let incomingLength = simd_length(incoming)
            let outgoingLength = simd_length(outgoing)
            guard incomingLength > 1e-7, outgoingLength > 1e-7 else { return false }
            return simd_dot(incoming / incomingLength, outgoing / outgoingLength) < threshold
        }
    }

    /// The surface vertex nearest each of `points`, horizontally.
    ///
    /// Exact rather than approximate, for the use it is put to: the top surface was clipped *to* the
    /// outline, so every boundary vertex is already a vertex of it and the nearest one is that same
    /// point. Resolved once when the effect goes on and read back on every pan step, because a pan
    /// moves no vertex horizontally — only its height.
    static func nearestVertices(
        to points: [SIMD2<Float>],
        in positions: [SIMD3<Float>]
    ) -> [Int] {
        points.compactMap { point in
            var best: Int?
            var bestDistance = Float.greatestFiniteMagnitude
            for index in positions.indices {
                let position = positions[index]
                let distance = simd_length_squared(SIMD2(position.x, position.z) - point)
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            return best
        }
    }
}
