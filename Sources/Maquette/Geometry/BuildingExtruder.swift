import Foundation
import RealityKit
import simd

/// Turns OpenStreetMap building footprints into extruded blocks standing on the chunk's terrain.
///
/// ## Why buildings come from a separate source at all
///
/// The chunk's own surface cannot carry them. Both elevation providers are bare-earth models —
/// Mapzen Terrarium and MapTiler terrain-rgb both describe the ground with structures removed — and
/// even if they did not, a heightfield holds one Y per horizontal position, so it cannot express a
/// vertical wall. Buildings are additional geometry resting on the terrain, not detail within it.
///
/// ## What is deliberately approximate
///
/// A footprint's base sits at the **lowest** terrain sample under its outline, not at each corner's
/// own height. Following the ground per-corner would shear the walls; taking the mean would sink the
/// downhill side into the hill. Taking the minimum means a building on a slope stands on its lowest
/// corner and floats slightly at its highest, which reads correctly from every angle a diorama is
/// looked at, and the error is bounded by the relief across one footprint — a few meters at most.
enum BuildingExtruder {
    /// A footprint already carried into diorama space, with the box it occupies there.
    ///
    /// The projection is the expensive half of a cut — `TerrainAnchor.dioramaPoint(for:)` is a
    /// Mercator transform per corner — and it is also the half that never changes: the anchor
    /// survives a roll, so a geographic corner keeps the diorama position it was first given for the
    /// life of the chunk. Only which of them the outline covers changes as the ground slides. So the
    /// projection is done once at fetch and every later cut reads these.
    ///
    /// The bounds ride along because a cut is mostly rejection. A downtown fetch is thousands of
    /// footprints against an outline covering a fraction of them, and comparing two boxes settles
    /// nearly all of it without a point-in-polygon test against a 128-sided circle.
    struct PlanarFootprint: Sendable {
        let outline: [SIMD2<Float>]
        let minCorner: SIMD2<Float>
        let maxCorner: SIMD2<Float>
        let heightMeters: Float
    }

    /// One extruded footprint, and where its triangles sit in the arena.
    struct Block: Sendable {
        let outline: [SIMD2<Float>]
        let minCorner: SIMD2<Float>
        let maxCorner: SIMD2<Float>
        /// The block's triangles, as a span of ``Blocks/indices``.
        let indexStart: Int
        let indexCount: Int
        /// The box the block's own vertices occupy, so a selection's bounds are a union of boxes
        /// rather than a second pass over every position.
        let lo: SIMD3<Float>
        let hi: SIMD3<Float>
    }

    /// Every footprint the fetch covered, extruded once into one arena.
    ///
    /// This is the whole reason panning is cheap. A block's geometry is fixed by its footprint and
    /// the ground under it, and neither moves when the chunk pans — the outline slides over ground
    /// that stays where it is. So triangulating the roof, sampling the terrain for the base, and
    /// winding the walls all happen once, for the margin ring as well as the chunk, and a pan step
    /// only has to decide *which* of these blocks the outline covers now.
    ///
    /// Laid out as one vertex array and one index array rather than a mesh per building because that
    /// is what a selection wants: the vertices are uploaded once and never rewritten, and a cut is a
    /// gather of index spans out of `indices`.
    struct Blocks: Sendable {
        var vertices: [Tiles3DVertex] = []
        var indices: [UInt32] = []
        var blocks: [Block] = []
        /// How many footprints could not be triangulated. Counted here because it is a property of
        /// the fetch, not of a pan step.
        var droppedDegenerate = 0

        var isEmpty: Bool { blocks.isEmpty }
    }

    /// Which blocks the outline covers at one pan offset, as the indices that draw them.
    struct Selection: Sendable {
        /// Index spans of the kept blocks, gathered out of ``Blocks/indices``. These address the
        /// arena's vertices directly, so nothing has to be re-indexed.
        var indices: [UInt32] = []
        var kept = 0
        /// How many blocks were dropped for crossing or lying outside the outline. On a panning
        /// chunk this counts the margin ring too, so it is not a measure of how ragged the rim is.
        var droppedOutside = 0
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        var isEmpty: Bool { indices.isEmpty }
        var bounds: BoundingBox { isEmpty ? BoundingBox() : BoundingBox(min: lo, max: hi) }
    }

    /// Carries footprints from geographic coordinates into diorama space.
    ///
    /// Done once per fetch, because the answer never changes: `TerrainAnchor` fixes the mapping for
    /// the life of the chunk — a roll replaces the ground under the anchor, not the anchor — so a
    /// corner's diorama position is as permanent as its latitude and longitude. Panning changes only
    /// which of them the outline covers, which is ``extrude(footprints:heightField:boundary:panOffset:style:)``'s
    /// question and a far cheaper one.
    ///
    /// Footprints with fewer than three corners are dropped here rather than counted, since they
    /// could never have been extruded and reporting them once per cut would say a pan had lost
    /// something.
    @concurrent
    static func project(
        _ footprints: [BuildingFootprint],
        anchor: TerrainAnchor
    ) async -> [PlanarFootprint] {
        var planar: [PlanarFootprint] = []
        planar.reserveCapacity(footprints.count)

        for (index, footprint) in footprints.enumerated() {
            if index & 0xFF == 0, Task.isCancelled { return planar }
            guard footprint.outline.count >= 3 else { continue }

            var outline: [SIMD2<Float>] = []
            outline.reserveCapacity(footprint.outline.count)
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            for coordinate in footprint.outline {
                let point = anchor.dioramaPoint(for: coordinate)
                let corner = SIMD2(Float(point.x), Float(point.y))
                lo = simd_min(lo, corner)
                hi = simd_max(hi, corner)
                outline.append(corner)
            }

            planar.append(
                PlanarFootprint(
                    outline: outline,
                    minCorner: lo,
                    maxCorner: hi,
                    heightMeters: Float(footprint.heightMeters)
                )
            )
        }
        return planar
    }

    /// Folds newly fetched footprints in with the ones already held, keeping the target box's worth.
    ///
    /// Two things have to happen at once here, and both are about a pan that keeps going.
    ///
    /// A provider is asked for a box and answers with whatever it holds that *touches* it: Overpass
    /// returns any way crossing the bounds, and the vector-tile provider returns whole tiles. So a
    /// strip abutting ground already fetched brings back buildings that are already in hand, and
    /// pasting the two lists together would draw those twice — at double the triangles, z-fighting
    /// with themselves. A footprint centred on ground the previous fetch covered is therefore taken
    /// to be one of that fetch's, which is exact for both providers unless a query hit its cap.
    ///
    /// And what falls outside `target` is dropped rather than remembered. The arena is rebuilt whole
    /// whenever the ground moves under it, so a city the chunk left an hour ago would be re-extruded
    /// on every roll for the rest of the session. The trade is that panning back across the seam
    /// fetches it again.
    ///
    /// - Parameters:
    ///   - fetched: Footprints just returned, in diorama space.
    ///   - held: Footprints already in hand.
    ///   - target: The ground the result should cover.
    ///   - covered: The ground `held` came from, which is where duplicates can be recognised.
    static func merge(
        _ fetched: [PlanarFootprint],
        into held: [PlanarFootprint],
        covering target: GroundBox,
        alreadyHeld covered: GroundBox
    ) -> [PlanarFootprint] {
        var footprints = held.filter { target.overlaps(lo: $0.minCorner, hi: $0.maxCorner) }
        for footprint in fetched {
            let centre = (footprint.minCorner + footprint.maxCorner) / 2
            guard !covered.contains(centre),
                  target.overlaps(lo: footprint.minCorner, hi: footprint.maxCorner)
            else { continue }
            footprints.append(footprint)
        }
        return footprints
    }

    /// Extrudes every footprint the fetch covered, once, into one arena.
    ///
    /// ## Why this is separate from the cut
    ///
    /// The outline is fixed and the ground slides beneath it, so ground at diorama point P is drawn
    /// at `P - panOffset`. Positions therefore stay in ground space — a footprint occupies the same
    /// vertices however far the chunk has panned, and ``BuildingsEntity`` carries the whole mesh by
    /// `-panOffset` on its transform — and it is only the *membership* test that moves.
    ///
    /// So none of the work here is a function of the pan: the roof triangulation, the winding flip,
    /// the terrain samples that put the base on the ground. Doing it per pan step is what made the
    /// first version of this too slow to drag against; the whole fetch is extruded once instead, and
    /// ``select(from:boundary:panOffset:)`` picks blocks out of the result. The margin ring is
    /// extruded along with the chunk, because it is exactly the ground a pan is about to reach.
    ///
    /// The one thing that *does* invalidate it is a roll: `baseY` comes from the height field, so
    /// ground replaced under the blocks means building again. That is rare and off the main actor,
    /// and until it lands the old arena is still drawable.
    ///
    /// - Parameters:
    ///   - footprints: Footprints already in diorama space, from ``project(_:anchor:)``.
    ///   - heightField: The ground each footprint stands on.
    ///   - style: Height defaults and the vertical scale to draw at.
    ///
    /// ## Isolation
    ///
    /// `@concurrent` rather than a bare `nonisolated async`, because the whole point of this being
    /// async is to get off the main actor and the bare spelling only does that by default. Under
    /// `NonisolatedNonsendingByDefault` — an upcoming feature now, the default in Swift 7 — a
    /// `nonisolated async` function runs on its *caller's* executor instead, which would quietly put
    /// the whole loop back on the main actor without a diagnostic anywhere.
    ///
    /// The attribute has to carry that on its own: where this runs is not observable from a test.
    /// Timing it from the calling actor looks like it should work and does not — an `async let`
    /// child races the parent's own resumption onto the actor's queue, so the stall it measures is
    /// scheduling order, not isolation. Written that way it passes just as happily with the extrude
    /// pinned to `@MainActor`, which is how the attempt was caught. What settled it was a temporary
    /// `Thread.isMainThread` probe on device — `false`, on a thread the store was not running on.
    ///
    /// The cost is worth stating precisely, because it is the reason the split exists: 8,480
    /// downtown footprints extrude in **31 ms in a Release build and 3,164 ms in a Debug one**. The
    /// loop is scalar arithmetic over every corner of every footprint, the shape unoptimised Swift
    /// punishes hardest — the same ~100× that `Tiles3DClipper` shows. Paid once at load that is a
    /// stall nobody sees; paid per pan step in a debug build it is seconds of the mesh hanging past
    /// the rim, which is what the split removes.
    @concurrent
    static func build(
        footprints: [PlanarFootprint],
        heightField: TerrainHeightField,
        style: BuildingStyle
    ) async -> Blocks {
        var mesh = IndexedMesh()
        // A typical footprint is a quad: 4 side quads plus a roof fan is about 20 vertices.
        mesh.reserve(vertices: footprints.count * 20, indices: footprints.count * 54)

        var blocks: [Block] = []
        blocks.reserveCapacity(footprints.count)
        var droppedDegenerate = 0
        let scale = style.verticalScale(of: heightField)

        for (index, footprint) in footprints.enumerated() {
            // A preset switch mid-extrude should not pay for footprints nobody will see. Checked in
            // batches because the cost is per-check, not per-footprint, and abandoned whole: half an
            // arena is not something a later cut could safely select out of.
            if index & 0xFF == 0, Task.isCancelled { return Blocks() }

            let vertexStart = mesh.vertices.count
            let indexStart = mesh.indices.count
            let height = footprint.heightMeters * scale
            guard addBlock(footprint.outline, height: max(height, style.minimumDrawnHeight),
                           heightField: heightField, into: &mesh)
            else {
                droppedDegenerate += 1
                continue
            }

            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for vertex in mesh.vertices[vertexStart...] {
                lo = simd_min(lo, vertex.position)
                hi = simd_max(hi, vertex.position)
            }

            blocks.append(
                Block(
                    outline: footprint.outline,
                    minCorner: footprint.minCorner,
                    maxCorner: footprint.maxCorner,
                    indexStart: indexStart,
                    indexCount: mesh.indices.count - indexStart,
                    lo: lo,
                    hi: hi
                )
            )
        }

        return Blocks(
            vertices: mesh.vertices,
            indices: mesh.indices,
            blocks: blocks,
            droppedDegenerate: droppedDegenerate
        )
    }

    /// Picks the blocks the outline covers at this pan offset.
    ///
    /// This is the whole of a pan step. No geometry is produced — the arena's vertices are already on
    /// the GPU and never change — so what comes back is a list of indices, and drawing it is an index
    /// rewrite rather than a mesh rebuild.
    ///
    /// Two things keep it cheap. Blocks are tested against their bounding boxes first, which settles
    /// nearly all of a downtown fetch without walking a 128-sided ring; and neighbouring blocks that
    /// are both kept occupy neighbouring spans of `blocks.indices`, so a run of them is copied in one
    /// go instead of one span at a time. At rest almost every block inside the outline is in one long
    /// run, so the gather is close to a single memcpy.
    ///
    /// ## Blocks crossing the rim are dropped, not clipped
    ///
    /// Clipping them correctly would mean clipping *against* a boundary that may be concave, and
    /// Sutherland-Hodgman is exact only when the clip region is convex — the same trap
    /// `TerrainSolidGenerator` documents, where intersecting a concave outline's edge half-planes
    /// punches a notch at every reflex corner. The exact answer exists (clip the boundary against
    /// each footprint, as the terrain does per cell) but a building straddling the rim is a rare
    /// enough case that dropping it costs less than the machinery to keep it.
    ///
    /// It also has to stay a whole-block decision for the selection to work at all: a clipped block
    /// would need new vertices, and new vertices are exactly what this avoids producing.
    @concurrent
    static func select(
        from blocks: Blocks,
        boundary: DioramaBoundary,
        panOffset: SIMD2<Float> = .zero
    ) async -> Selection {
        var selection = Selection()
        guard !blocks.blocks.isEmpty else { return selection }
        selection.indices.reserveCapacity(blocks.indices.count)

        // Sliding the outline over the ground is the same test as sliding the ground under the
        // outline, and this way the blocks' own boxes never have to be recomputed.
        let low = boundary.minCorner + panOffset
        let high = low + boundary.extent

        var runStart = -1
        var runEnd = -1

        for (index, block) in blocks.blocks.enumerated() {
            if index & 0xFF == 0, Task.isCancelled { return selection }

            // Boxes first. Most of a downtown fetch is nowhere near the outline at any one moment,
            // and four comparisons settle those without walking the ring.
            guard block.maxCorner.x >= low.x, block.minCorner.x <= high.x,
                  block.maxCorner.y >= low.y, block.minCorner.y <= high.y,
                  block.outline.allSatisfy({ boundary.contains($0 - panOffset) })
            else {
                selection.droppedOutside += 1
                continue
            }

            if runStart < 0 {
                runStart = block.indexStart
            } else if runEnd != block.indexStart {
                selection.indices.append(contentsOf: blocks.indices[runStart..<runEnd])
                runStart = block.indexStart
            }
            runEnd = block.indexStart + block.indexCount

            selection.kept += 1
            selection.lo = simd_min(selection.lo, block.lo)
            selection.hi = simd_max(selection.hi, block.hi)
        }

        if runStart >= 0 {
            selection.indices.append(contentsOf: blocks.indices[runStart..<runEnd])
        }
        return selection
    }

    /// Adds one footprint's walls and roof. Returns `false` if the outline is degenerate.
    ///
    /// OSM stores rings in whichever direction the mapper drew them, so the ring is first turned to
    /// match `DioramaBoundary`'s winding. Everything downstream then gets what it already assumes:
    /// `PolygonClipping.triangulate` preserves the winding it is given, so the roof comes out facing
    /// up, and `DioramaBoundary.outwardNormal(forEdgeFrom:to:)` names the wall normals correctly.
    static func addBlock(
        _ footprint: [SIMD2<Float>],
        height: Float,
        heightField: TerrainHeightField,
        into mesh: inout IndexedMesh
    ) -> Bool {
        guard footprint.count >= 3 else { return false }

        let outline = PolygonClipping.signedArea(footprint) > 0
            ? footprint.reversed().map { $0 }
            : footprint

        let triangles = PolygonClipping.triangulate(outline, minimumArea: 0)
        guard !triangles.isEmpty else { return false }

        // The base is the lowest ground under the footprint, so a building on a slope is buried at
        // its uphill corner rather than hovering at its downhill one.
        var baseY = Float.greatestFiniteMagnitude
        for point in outline {
            baseY = min(baseY, heightField.surfaceY(atX: point.x, z: point.y))
        }
        // Sunk a little, so the seam where a wall meets the terrain is never a visible gap on
        // ground that undulates between the sampled corners.
        baseY -= height * 0.02
        let topY = baseY + height

        addWalls(outline, baseY: baseY, topY: topY, into: &mesh)
        addRoof(outline, triangles: triangles, y: topY, into: &mesh)
        return true
    }

    private static func addWalls(
        _ outline: [SIMD2<Float>],
        baseY: Float,
        topY: Float,
        into mesh: inout IndexedMesh
    ) {
        for i in outline.indices {
            let a = outline[i]
            let b = outline[(i + 1) % outline.count]
            guard simd_distance(a, b) > 1e-7 else { continue }
            let outward = DioramaBoundary.outwardNormal(forEdgeFrom: a, to: b)

            // Same vertex order and diagonal as `TerrainSolidGenerator.appendWallQuad`, so a cut
            // wall and a building wall wind the same way.
            let aTop = mesh.append(
                position: SIMD3(a.x, topY, a.y), normal: outward, uv: SIMD2(0, 1))
            let aBottom = mesh.append(
                position: SIMD3(a.x, baseY, a.y), normal: outward, uv: SIMD2(0, 0))
            let bTop = mesh.append(
                position: SIMD3(b.x, topY, b.y), normal: outward, uv: SIMD2(1, 1))
            let bBottom = mesh.append(
                position: SIMD3(b.x, baseY, b.y), normal: outward, uv: SIMD2(1, 0))

            mesh.appendTriangle(aTop, aBottom, bBottom)
            mesh.appendTriangle(aTop, bBottom, bTop)
        }
    }

    private static func addRoof(
        _ outline: [SIMD2<Float>],
        triangles: [(Int, Int, Int)],
        y: Float,
        into mesh: inout IndexedMesh
    ) {
        let up = SIMD3<Float>(0, 1, 0)
        var base: [UInt32] = []
        base.reserveCapacity(outline.count)
        for point in outline {
            base.append(mesh.append(position: SIMD3(point.x, y, point.y), normal: up, uv: point))
        }
        for (a, b, c) in triangles {
            mesh.appendTriangle(base[a], base[b], base[c])
        }
    }
}
