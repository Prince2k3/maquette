import Foundation
import simd

/// The edges of a triangle mesh, and which triangles meet along each one.
///
/// Built for the ink effect, which draws two kinds of line and needs the same structure for both: a
/// *border* edge has one triangle and is where the surface ends, so it traces the cut outline; a
/// *crease* edge has two triangles that disagree sharply about which way the surface faces, so it
/// traces a ridge or a cliff. Everything else is a smooth join and is drawn as nothing at all.
///
/// Two properties of this library's chunks make it worth separating the structure from the test.
///
/// The chunk's top surface does **not** share vertices everywhere: interior grid cells reuse their
/// neighbours' corners, but a cell the boundary clips appends its own, so two cells meeting along a
/// clipped seam hold four coincident vertices at two distinct indices. Comparing indices alone would
/// call every one of those seams a border and ink a cage around each boundary cell, so vertices are
/// welded by horizontal position first.
///
/// And the adjacency is **invariant under a pan**. Sliding the terrain changes heights, normals and
/// texture coordinates, never topology or horizontal position — so the expensive half of this, the
/// hashing, is done once when the effect goes on, and a pan step re-reads positions through a
/// structure it does not have to rebuild.
struct MeshEdges {
    /// A triangle that has no neighbour across an edge.
    static let noTriangle = UInt32.max

    /// One undirected edge of the welded mesh.
    struct Edge {
        /// Welded vertex indices, into the mesh's own position buffer.
        var a: UInt32
        var b: UInt32
        /// Triangles sharing this edge, as triangle numbers — index into `indices` divided by three.
        /// `right` is ``noTriangle`` on a border edge.
        var left: UInt32
        var right: UInt32

        var isBorder: Bool { right == MeshEdges.noTriangle }
    }

    private(set) var edges: [Edge] = []

    /// Triangle corner indices, welded, so a face normal can be recomputed after a pan.
    private var triangles: [UInt32] = []

    /// Interior edges grouped by the patch of ground they sit over, as a run per patch.
    ///
    /// The grouping is what lets a crease budget be spread evenly rather than spent wherever the
    /// terrain happens to be roughest, and like the adjacency it survives a pan: an edge's midpoint
    /// moves vertically as the ground slides and never horizontally, so which patch it belongs to is
    /// settled once.
    private var edgesByPatch: [UInt32] = []
    private var patchStarts: [Int] = []

    /// How many patches hold at least one interior edge, which is what a budget is divided between.
    private var occupiedPatches = 0

    /// Every triangle's geometric normal at the positions last passed to ``creases(in:minimumAngle:density:)``.
    ///
    /// Held rather than derived per edge because a triangle sits on three of them, so asking each
    /// edge for its two neighbours' normals normalises every triangle three times over. One pass
    /// down the triangles first makes it once, and reads the position buffer in order while it is
    /// at it rather than jumping about it. Kept between steps so a pan reuses the allocation.
    private var faceNormals: [SIMD3<Float>] = []

    /// How many patches the chunk is divided into along each axis when spreading a crease budget.
    ///
    /// Wants to be fine enough that a patch is smaller than a landform — a budget spread over four
    /// quadrants would still let one mountain range take a quarter of the drawing — and coarse
    /// enough that a patch holds enough edges to choose between. At 24 across, a 256-cell sampling
    /// grid gives roughly a hundred candidates per patch.
    private static let patchesAcross = 24
    /// Builds the edge structure for a mesh.
    ///
    /// - Parameters:
    ///   - positions: Vertex positions.
    ///   - indices: Triangle indices, three per triangle.
    ///   - tolerance: How close two vertices must be horizontally to count as the same point.
    ///     Wants to be far below the sampling grid's spacing and far above the rounding error a
    ///     clip introduces; a small fraction of the chunk's extent sits comfortably between the two.
    init(positions: [SIMD3<Float>], indices: [UInt32], tolerance: Float) {
        let welded = Self.weld(positions: positions, tolerance: tolerance)
        guard indices.count >= 3 else { return }

        triangles.reserveCapacity(indices.count)
        for index in indices {
            triangles.append(welded[Int(index)])
        }

        // Keyed by the edge's two welded endpoints in a fixed order, so the two triangles either
        // side of an edge arrive at the same entry whichever way round they wind it.
        var slots: [UInt64: Int] = [:]
        slots.reserveCapacity(indices.count)
        edges.reserveCapacity(indices.count)

        let triangleCount = triangles.count / 3
        for triangle in 0..<triangleCount {
            let corners = (
                triangles[triangle * 3],
                triangles[triangle * 3 + 1],
                triangles[triangle * 3 + 2]
            )
            add(corners.0, corners.1, triangle: UInt32(triangle), into: &slots)
            add(corners.1, corners.2, triangle: UInt32(triangle), into: &slots)
            add(corners.2, corners.0, triangle: UInt32(triangle), into: &slots)
        }

        groupIntoPatches(positions: positions)
    }

    /// Sorts the interior edges into a horizontal grid of patches, as runs in one flat buffer.
    private mutating func groupIntoPatches(positions: [SIMD3<Float>]) {
        let across = Self.patchesAcross
        patchStarts = [Int](repeating: 0, count: across * across + 1)
        guard let first = positions.first else { return }

        var low = SIMD2(first.x, first.z)
        var high = low
        for position in positions {
            low = simd_min(low, SIMD2(position.x, position.z))
            high = simd_max(high, SIMD2(position.x, position.z))
        }
        let extent = simd_max(high - low, SIMD2(repeating: 1e-6))
        let scale = SIMD2(Float(across), Float(across)) / extent

        func patch(of edge: Edge) -> Int {
            let a = positions[Int(edge.a)]
            let b = positions[Int(edge.b)]
            let midpoint = (SIMD2(a.x, a.z) + SIMD2(b.x, b.z)) / 2
            let cell = (midpoint - low) * scale
            let column = min(across - 1, max(0, Int(cell.x)))
            let row = min(across - 1, max(0, Int(cell.y)))
            return row * across + column
        }

        // Counting sort, so the runs come out contiguous without a dictionary or a sort.
        for edge in edges where !edge.isBorder {
            patchStarts[patch(of: edge) + 1] += 1
        }
        for index in 1..<patchStarts.count {
            if patchStarts[index] > 0 { occupiedPatches += 1 }
            patchStarts[index] += patchStarts[index - 1]
        }

        var cursors = patchStarts
        edgesByPatch = [UInt32](repeating: 0, count: patchStarts[patchStarts.count - 1])
        for index in edges.indices where !edges[index].isBorder {
            let slot = patch(of: edges[index])
            edgesByPatch[cursors[slot]] = UInt32(index)
            cursors[slot] += 1
        }
    }

    private mutating func add(
        _ a: UInt32,
        _ b: UInt32,
        triangle: UInt32,
        into slots: inout [UInt64: Int]
    ) {
        guard a != b else { return }
        let low = UInt64(min(a, b))
        let high = UInt64(max(a, b))
        let key = low << 32 | high

        if let slot = slots[key] {
            // A third triangle on one edge means non-manifold geometry. Keeping the first pair is
            // the conservative answer: the edge stays a crease candidate rather than becoming a
            // border, so a fold in the data cannot open an ink line across the middle of a surface.
            if edges[slot].right == Self.noTriangle {
                edges[slot].right = triangle
            }
        } else {
            slots[key] = edges.count
            edges.append(Edge(a: UInt32(low), b: UInt32(high), left: triangle, right: Self.noTriangle))
        }
    }

    /// Every edge where the surface ends, as segments in the mesh's own space.
    ///
    /// On a chunk's top surface this is exactly the cut outline, concave corners included — the
    /// surface was clipped to the boundary when it was generated, so its border already is the
    /// boundary and nothing here has to repeat that clip.
    func borders(in positions: [SIMD3<Float>]) -> [ContourExtractor.Segment] {
        edges.compactMap { edge in
            guard edge.isBorder else { return nil }
            return ContourExtractor.Segment(a: positions[Int(edge.a)], b: positions[Int(edge.b)])
        }
    }

    /// Every edge whose two triangles turn through more than `minimumAngle`, in radians.
    ///
    /// Recomputed rather than cached because it genuinely changes on every pan step: the adjacency
    /// holds, but the heights either side of an edge are re-sampled, so a ridge that was sharp under
    /// one stretch of ground is smooth under the next.
    ///
    /// - Parameter density: The largest share of the interior edges that may be returned, or zero
    ///   for all of them. The share is divided evenly between the patches of ground holding edges
    ///   and each patch keeps its own sharpest, so what comes back is bounded *and* spread — an
    ///   angle alone gives neither. A fixed threshold makes the drawing's density a property of the
    ///   terrain rather than of the drawing: ground that happens to be rugged is inked until it is
    ///   solid black while flat ground a few hundred metres away is left bare, and panning from one
    ///   to the other changes the whole look of the chunk. It also lets the work grow without limit,
    ///   which the pan step pays for.
    mutating func creases(
        in positions: [SIMD3<Float>],
        minimumAngle: Float,
        density: Float = 0
    ) -> [ContourExtractor.Segment] {
        guard minimumAngle > 0 else { return [] }
        let threshold = cos(minimumAngle)
        var segments: [ContourExtractor.Segment] = []

        var allowance = Int.max
        if density > 0, density < 1, occupiedPatches > 0 {
            let total = Float(edgesByPatch.count) * density
            allowance = max(1, Int((total / Float(occupiedPatches)).rounded()))
        }

        refreshFaceNormals(in: positions)

        // Sharpest first within a patch, so a budget spends itself on the folds that read as folds.
        var candidates: [(sharpness: Float, edge: UInt32)] = []
        for patch in 0..<(patchStarts.count - 1) {
            candidates.removeAll(keepingCapacity: true)
            for slot in patchStarts[patch]..<patchStarts[patch + 1] {
                let edge = edges[Int(edgesByPatch[slot])]
                // A degenerate triangle carries a normal of NaN, so this comparison is false and the
                // edge is passed over — the same answer the old per-edge `nil` gave, without an
                // extra test on the hot path for a case that only arises in a clipped sliver.
                let facing = simd_dot(faceNormals[Int(edge.left)], faceNormals[Int(edge.right)])
                guard facing < threshold else { continue }
                candidates.append((facing, edgesByPatch[slot]))
            }
            if candidates.count > allowance {
                candidates.sort { $0.sharpness < $1.sharpness }
                candidates.removeLast(candidates.count - allowance)
            }
            for candidate in candidates {
                let edge = edges[Int(candidate.edge)]
                segments.append(
                    ContourExtractor.Segment(a: positions[Int(edge.a)], b: positions[Int(edge.b)])
                )
            }
        }
        return segments
    }

    /// Recomputes every triangle's geometric normal for the positions given.
    ///
    /// Taken from the positions rather than from the mesh's shading normals on purpose: shading
    /// normals on this library's terrain are central differences of the height field, which are
    /// smooth across a cliff by construction and would report no crease exactly where the sharpest
    /// one is.
    ///
    /// A degenerate triangle gets NaN, which propagates through the dot product and fails the
    /// dihedral comparison, so it is skipped rather than read as a fold.
    private mutating func refreshFaceNormals(in positions: [SIMD3<Float>]) {
        let count = triangles.count / 3
        if faceNormals.count != count {
            faceNormals = [SIMD3<Float>](repeating: .zero, count: count)
        }
        guard count > 0 else { return }

        positions.withUnsafeBufferPointer { positions in
            triangles.withUnsafeBufferPointer { corners in
                faceNormals.withUnsafeMutableBufferPointer { normals in
                    for triangle in 0..<count {
                        let base = triangle * 3
                        let a = positions[Int(corners[base])]
                        let b = positions[Int(corners[base + 1])]
                        let c = positions[Int(corners[base + 2])]
                        let cross = simd_cross(b - a, c - a)
                        let length = simd_length(cross)
                        normals[triangle] = length > 1e-12
                            ? cross / length
                            : SIMD3<Float>(repeating: .nan)
                    }
                }
            }
        }
    }

    /// Maps every vertex to a representative for the point it sits on.
    ///
    /// Horizontal position only. Two vertices sharing an `(x, z)` on this library's terrain share a
    /// height by construction — both are sampled from the same height field at the same place — and
    /// welding on all three coordinates would instead make the result depend on how far the terrain
    /// had panned when the effect was switched on.
    private static func weld(positions: [SIMD3<Float>], tolerance: Float) -> [UInt32] {
        var representative = [UInt32](repeating: 0, count: positions.count)
        guard tolerance > 0 else {
            for index in positions.indices { representative[index] = UInt32(index) }
            return representative
        }

        let scale = 1 / tolerance
        var seen: [SIMD2<Int64>: UInt32] = [:]
        seen.reserveCapacity(positions.count)

        for index in positions.indices {
            let position = positions[index]
            let cell = SIMD2<Int64>(
                Int64((position.x * scale).rounded()),
                Int64((position.z * scale).rounded())
            )

            // The neighbouring cells as well as the vertex's own, because rounding to a grid splits
            // any pair that straddles a cell edge — and two vertices land within a rounding error of
            // each other precisely when the clip computed the same point twice, which is exactly the
            // pair that must weld. Missing one puts a stray ink line down a boundary cell's seam.
            var match: UInt32?
            for dx in Int64(-1)...1 where match == nil {
                for dz in Int64(-1)...1 {
                    if let existing = seen[cell &+ SIMD2(dx, dz)] {
                        match = existing
                        break
                    }
                }
            }

            if let match {
                representative[index] = match
                // Claimed for this cell too, so a run of near-coincident points chains onto the same
                // representative instead of pairing off.
                seen[cell] = match
            } else {
                seen[cell] = UInt32(index)
                representative[index] = UInt32(index)
            }
        }
        return representative
    }
}
