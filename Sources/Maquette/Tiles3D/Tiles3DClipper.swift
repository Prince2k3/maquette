import Foundation
import RealityKit
import simd

/// Cuts streamed 3D Tiles geometry down to the diorama's outline.
///
/// The terrain pipeline clips a heightfield, which is a two-dimensional problem. Photogrammetry is
/// arbitrary triangle soup — building facades are vertical, and bridges and overhangs are
/// multi-valued — so this clips **in three dimensions**, against the vertical planes raised from the
/// outline's edges. Projecting triangles onto the horizontal plane first would collapse every
/// facade to a line and delete it.
///
/// Cut faces are left open rather than capped. Capping arbitrary sliced geometry is the expensive
/// part of mesh clipping and is unnecessary here, because the diorama's base sits directly beneath
/// the cut and hides it.
enum Tiles3DClipper {
    /// A vertex carrying everything that must survive interpolation along a clipped edge.
    private struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var uv: SIMD2<Float>

        static func interpolate(_ from: Vertex, _ to: Vertex, _ t: Float) -> Vertex {
            Vertex(
                position: from.position + (to.position - from.position) * t,
                normal: from.normal + (to.normal - from.normal) * t,
                uv: from.uv + (to.uv - from.uv) * t
            )
        }
    }

    /// Clips a tile's mesh parts to the prism, baking the tile's placement into the vertices.
    ///
    /// The placement transform is applied up front rather than left on the entity because it
    /// carries rotation: a prism that is vertical in diorama space would be tilted in the tile's
    /// own space. Callers should therefore leave the resulting entity's transform as identity.
    ///
    /// - Returns: The clipped mesh parts, or an empty array when nothing survives.
    static func clip(
        descriptors: [MeshDescriptor],
        placement: simd_float4x4,
        to prism: BoundaryPrism
    ) -> [MeshDescriptor] {
        // Normals transform by the inverse-transpose; for the rigid transforms 3D Tiles uses, the
        // upper-left block is enough.
        let normalMatrix = simd_float3x3(
            SIMD3(placement.columns.0.x, placement.columns.0.y, placement.columns.0.z),
            SIMD3(placement.columns.1.x, placement.columns.1.y, placement.columns.1.z),
            SIMD3(placement.columns.2.x, placement.columns.2.y, placement.columns.2.z)
        )

        var clipped: [MeshDescriptor] = []
        for descriptor in descriptors {
            if let result = clipPart(descriptor, placement: placement, normalMatrix: normalMatrix, prism: prism) {
                clipped.append(result)
            }
        }
        return clipped
    }

    // MARK: - Per-Part Clipping

    private static func clipPart(
        _ descriptor: MeshDescriptor,
        placement: simd_float4x4,
        normalMatrix: simd_float3x3,
        prism: BoundaryPrism
    ) -> MeshDescriptor? {
        let sourcePositions = descriptor.positions.elements
        guard !sourcePositions.isEmpty else { return nil }

        guard case .triangles(let sourceIndices) = descriptor.primitives, sourceIndices.count >= 3 else {
            return nil
        }

        let sourceNormals = descriptor.normals?.elements
        let sourceUVs = descriptor.textureCoordinates?.elements

        // Bake placement into the vertices so the prism stays vertical relative to them.
        var vertices: [Vertex] = []
        vertices.reserveCapacity(sourcePositions.count)
        for index in sourcePositions.indices {
            let local = sourcePositions[index]
            let world = placement * SIMD4(local.x, local.y, local.z, 1)
            let normal = sourceNormals.map { simd_normalize(normalMatrix * $0[index]) } ?? SIMD3(0, 1, 0)
            vertices.append(Vertex(
                position: SIMD3(world.x, world.y, world.z),
                normal: normal,
                uv: sourceUVs?[index] ?? .zero
            ))
        }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        func emit(_ polygon: [Vertex]) {
            guard polygon.count >= 3 else { return }
            let base = UInt32(positions.count)
            for vertex in polygon {
                positions.append(vertex.position)
                normals.append(vertex.normal)
                uvs.append(vertex.uv)
            }
            // Triangle ∩ convex region is convex, so a fan is a valid triangulation.
            for offset in 1..<(polygon.count - 1) {
                indices.append(contentsOf: [base, base + UInt32(offset), base + UInt32(offset) + 1])
            }
        }

        for start in stride(from: 0, to: sourceIndices.count - 2, by: 3) {
            let triangle = [
                vertices[Int(sourceIndices[start])],
                vertices[Int(sourceIndices[start + 1])],
                vertices[Int(sourceIndices[start + 2])],
            ]

            let footprint = triangle.map { SIMD2($0.position.x, $0.position.z) }
            var lower = footprint[0]
            var upper = footprint[0]
            for point in footprint.dropFirst() {
                lower = simd_min(lower, point)
                upper = simd_max(upper, point)
            }

            // Wholly outside the outline's extent.
            if upper.x < prism.lowerBound.x || lower.x > prism.upperBound.x
                || upper.y < prism.lowerBound.y || lower.y > prism.upperBound.y {
                continue
            }

            // Wholly inside: the overwhelmingly common case, kept without touching it.
            if footprint.allSatisfy(prism.contains) {
                emit(triangle)
                continue
            }

            for piece in prism.pieces(overlapping: lower, upper) {
                emit(clip(triangle: triangle, against: piece))
            }
        }

        guard !indices.isEmpty else { return nil }

        var result = MeshDescriptor(name: descriptor.name)
        result.positions = MeshBuffers.Positions(positions)
        result.normals = MeshBuffers.Normals(normals)
        if sourceUVs != nil {
            result.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        }
        result.primitives = .triangles(indices)
        return result
    }

    /// Clips a polygon against one convex piece's vertical planes.
    ///
    /// The inside test uses only X and Z, since the planes are vertical, but interpolation runs over
    /// the full vertex so height, shading, and texture survive the cut.
    private static func clip(triangle: [Vertex], against piece: BoundaryPrism.Piece) -> [Vertex] {
        var output = triangle

        for edge in piece.edges {
            guard output.count >= 3 else { return [] }
            let direction = edge.b - edge.a

            func side(_ vertex: Vertex) -> Float {
                let point = SIMD2(vertex.position.x, vertex.position.z)
                return direction.x * (point.y - edge.a.y) - direction.y * (point.x - edge.a.x)
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
                        output.append(crossing(previous, current, previousSide, currentSide))
                    }
                    output.append(current)
                } else if previousInside {
                    output.append(crossing(previous, current, previousSide, currentSide))
                }

                previous = current
                previousSide = currentSide
            }
        }

        return output.count >= 3 ? output : []
    }

    private static func crossing(
        _ from: Vertex,
        _ to: Vertex,
        _ fromSide: Float,
        _ toSide: Float
    ) -> Vertex {
        let denominator = fromSide - toSide
        guard abs(denominator) > .ulpOfOne else { return from }
        let t = min(max(fromSide / denominator, 0), 1)
        return Vertex.interpolate(from, to, t)
    }
}
