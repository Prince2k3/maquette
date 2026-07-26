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
/// Cut faces are left open rather than capped. Capping arbitrary sliced geometry — working out
/// which of the open loops bound solid and triangulating them — is the expensive and fragile part
/// of mesh clipping, and photogrammetry does not give the closed manifold that would make it
/// well-defined in the first place.
///
/// Instead the clip reports the segments it cut along, and `Tiles3DCutWall` extrudes those straight
/// down to the tray. That closes the silhouette, which is the only part anyone sees, without ever
/// having to decide what is inside the shell.
enum Tiles3DClipper {
    /// What a clip produced: the surviving geometry, and where it was cut.
    struct Result {
        var descriptors: [MeshDescriptor] = []
        var cutEdges: [Tiles3DCutEdge] = []

        var isEmpty: Bool { descriptors.isEmpty }
    }

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
    /// - Returns: The clipped mesh parts and the segments they were cut along. Empty when nothing
    ///   survives.
    static func clip(
        descriptors: [MeshDescriptor],
        placement: simd_float4x4,
        to prism: BoundaryPrism
    ) -> Result {
        // Normals transform by the inverse-transpose; for the rigid transforms 3D Tiles uses, the
        // upper-left block is enough.
        let normalMatrix = simd_float3x3(
            SIMD3(placement.columns.0.x, placement.columns.0.y, placement.columns.0.z),
            SIMD3(placement.columns.1.x, placement.columns.1.y, placement.columns.1.z),
            SIMD3(placement.columns.2.x, placement.columns.2.y, placement.columns.2.z)
        )

        var result = Result()
        for descriptor in descriptors {
            guard let part = clipPart(
                descriptor,
                placement: placement,
                normalMatrix: normalMatrix,
                prism: prism,
                cutEdges: &result.cutEdges
            ) else { continue }
            result.descriptors.append(part)
        }
        return result
    }

    // MARK: - Per-Part Clipping

    private static func clipPart(
        _ descriptor: MeshDescriptor,
        placement: simd_float4x4,
        normalMatrix: simd_float3x3,
        prism: BoundaryPrism,
        cutEdges: inout [Tiles3DCutEdge]
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

        var scratch = Scratch()

        for start in stride(from: 0, to: sourceIndices.count - 2, by: 3) {
            let triangle = (
                vertices[Int(sourceIndices[start])],
                vertices[Int(sourceIndices[start + 1])],
                vertices[Int(sourceIndices[start + 2])]
            )

            let a = SIMD2(triangle.0.position.x, triangle.0.position.z)
            let b = SIMD2(triangle.1.position.x, triangle.1.position.z)
            let c = SIMD2(triangle.2.position.x, triangle.2.position.z)
            let lower = simd_min(a, simd_min(b, c))
            let upper = simd_max(a, simd_max(b, c))

            // Wholly outside the outline's extent.
            if upper.x < prism.lowerBound.x || lower.x > prism.upperBound.x
                || upper.y < prism.lowerBound.y || lower.y > prism.upperBound.y {
                continue
            }

            // The outline misses this triangle entirely, so it cannot span both sides of it: one
            // corner decides whether the whole thing is kept or dropped. This is the path almost
            // every triangle takes — a rim tile is mostly ground the outline has moved past — and
            // it exists to keep those off the exact clip, which costs 128 half-plane tests to reach
            // the same answer.
            if !prism.mayCrossOutline(lower, upper) {
                guard prism.contains(a) else { continue }
                emit([triangle.0, triangle.1, triangle.2])
                continue
            }

            // Wholly inside, but close enough to the outline that the grid could not tell.
            if prism.contains(a) && prism.contains(b) && prism.contains(c) {
                emit([triangle.0, triangle.1, triangle.2])
                continue
            }

            for piece in prism.pieces(overlapping: lower, upper) {
                let polygon = clip(triangle: triangle, against: piece, scratch: &scratch)
                guard !polygon.isEmpty else { continue }
                // Only the clipped path can produce a cut. A triangle kept whole was never sliced,
                // and the outline is tested rather than the piece so that the interior splits a
                // concave outline is broken into do not become walls through the middle.
                collectCutEdges(of: polygon, prism: prism, into: &cutEdges)
                emit(polygon)
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

    /// Records the edges of a clipped polygon that ended up lying on the outline.
    private static func collectCutEdges(
        of polygon: [Vertex],
        prism: BoundaryPrism,
        into cutEdges: inout [Tiles3DCutEdge]
    ) {
        guard polygon.count >= 3 else { return }
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            guard let edge = prism.boundaryEdge(
                along: SIMD2(a.position.x, a.position.z),
                SIMD2(b.position.x, b.position.z)
            ) else { continue }
            cutEdges.append(Tiles3DCutEdge(a: a.position, b: b.position, boundaryEdge: edge))
        }
    }

    /// Buffers reused across every triangle of a mesh part.
    ///
    /// Sutherland-Hodgman is written as "read the polygon, write a new one" per plane, and a
    /// circular outline is a 128-gon — so the obvious implementation heap-allocates 128 times per
    /// triangle, which on a tile of a few thousand triangles is where the entire cost of a pan step
    /// turned out to live. These are allocated once per mesh part and reused.
    private struct Scratch {
        var polygon: [Vertex] = []
        var next: [Vertex] = []
        var sides: [Float] = []
    }

    /// Clips a triangle against one convex piece's vertical planes.
    ///
    /// The inside test uses only X and Z, since the planes are vertical, but interpolation runs over
    /// the full vertex so height, shading, and texture survive the cut.
    ///
    /// Each plane is classified before it is applied, which is what makes a many-sided outline
    /// affordable. A triangle is small next to the outline, so it lies wholly inside almost every
    /// one of the 128 half-planes, and clipping against those is the identity — worth detecting for
    /// the cost of three dot products rather than paying for a full rewrite of the polygon. The
    /// converse ends the work outright: a triangle wholly outside any *one* plane of a convex region
    /// is outside the region, which is what a straddling tile's exterior triangles hit. Before this,
    /// they walked every remaining plane to arrive at the same answer.
    private static func clip(
        triangle: (Vertex, Vertex, Vertex),
        against piece: BoundaryPrism.Piece,
        scratch: inout Scratch
    ) -> [Vertex] {
        scratch.polygon.removeAll(keepingCapacity: true)
        scratch.polygon.append(triangle.0)
        scratch.polygon.append(triangle.1)
        scratch.polygon.append(triangle.2)

        for edge in piece.edges {
            let direction = edge.b - edge.a

            scratch.sides.removeAll(keepingCapacity: true)
            var anyInside = false
            var anyOutside = false
            for vertex in scratch.polygon {
                let side = direction.x * (vertex.position.z - edge.a.y)
                    - direction.y * (vertex.position.x - edge.a.x)
                scratch.sides.append(side)
                if side <= 0 { anyInside = true } else { anyOutside = true }
            }

            if !anyOutside { continue }
            if !anyInside { return [] }

            scratch.next.removeAll(keepingCapacity: true)
            scratch.next.reserveCapacity(scratch.polygon.count + 1)

            var previous = scratch.polygon[scratch.polygon.count - 1]
            var previousSide = scratch.sides[scratch.sides.count - 1]

            for index in scratch.polygon.indices {
                let current = scratch.polygon[index]
                let currentSide = scratch.sides[index]
                let currentInside = currentSide <= 0
                let previousInside = previousSide <= 0

                if currentInside {
                    if !previousInside {
                        scratch.next.append(crossing(previous, current, previousSide, currentSide))
                    }
                    scratch.next.append(current)
                } else if previousInside {
                    scratch.next.append(crossing(previous, current, previousSide, currentSide))
                }

                previous = current
                previousSide = currentSide
            }

            swap(&scratch.polygon, &scratch.next)
            if scratch.polygon.count < 3 { return [] }
        }

        return scratch.polygon.count >= 3 ? scratch.polygon : []
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
