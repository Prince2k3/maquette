import Foundation
import Testing
import simd
@testable import Maquette

/// `BoundaryPrism.mayCrossOutline` is what keeps the exact clip off the triangles that do not need
/// it, and it is only safe because it errs in one direction: it may claim a crossing that is not
/// there, but it must never miss one that is. Reporting no crossing is a licence to decide a whole
/// triangle from a single corner, so a false negative silently deletes geometry — or keeps geometry
/// that should have been cut away — rather than merely costing time.
///
/// These check that one-sidedness against the outline itself rather than against the grid's
/// internals, so the structure behind it stays free to change.
@Suite("Boundary Prism Crossing Tests")
struct BoundaryPrismCrossingTests {
    /// Whether any edge of the outline genuinely passes through the box — the ground truth the fast
    /// test has to be conservative about.
    ///
    /// This has to be the segment against the box, not the segment's *bounding box* against it. A
    /// long diagonal edge has a bounding box covering ground it never comes near, and treating that
    /// as a crossing would demand the fast test claim the same — which is the flooding these tests
    /// exist to rule out.
    private func outlineTouches(
        _ boundary: DioramaBoundary,
        _ lower: SIMD2<Float>,
        _ upper: SIMD2<Float>
    ) -> Bool {
        for index in 0..<boundary.edgeCount {
            let (a, b) = boundary.edge(index)
            // Separating axis in 2D: the two box axes, then the edge's own normal. If the box sits
            // wholly to one side of any of them, the segment misses it.
            if simd_max(a, b).x < lower.x || simd_min(a, b).x > upper.x { continue }
            if simd_max(a, b).y < lower.y || simd_min(a, b).y > upper.y { continue }

            let normal = SIMD2<Float>(-(b.y - a.y), b.x - a.x)
            let offset = simd_dot(normal, a)
            var below = false
            var above = false
            for corner in [
                lower, SIMD2(upper.x, lower.y), upper, SIMD2(lower.x, upper.y),
            ] {
                let side = simd_dot(normal, corner) - offset
                if side <= 0 { below = true }
                if side >= 0 { above = true }
            }
            if below && above { return true }
        }
        return false
    }

    /// Sweeps boxes across the outline and its surroundings, asserting the fast test never misses a
    /// crossing the outline actually makes.
    private func expectNoMissedCrossings(
        _ boundary: DioramaBoundary,
        scale: Float,
        extent: Float,
        boxSize: Float,
        steps: Int = 80,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let prism = BoundaryPrism(boundary: boundary, scale: scale)
        let scaled = DioramaBoundary(vertices: boundary.vertices.map { $0 / scale })

        var missed = 0
        var claimed = 0
        var truly = 0
        for i in 0...steps {
            for j in 0...steps {
                let centre = SIMD2<Float>(
                    -extent + 2 * extent * Float(i) / Float(steps),
                    -extent + 2 * extent * Float(j) / Float(steps)
                )
                let lower = centre - SIMD2(repeating: boxSize / 2)
                let upper = centre + SIMD2(repeating: boxSize / 2)

                let fast = prism.mayCrossOutline(lower, upper)
                let exact = outlineTouches(scaled, lower, upper)
                if exact { truly += 1 }
                if fast { claimed += 1 }
                if exact && !fast { missed += 1 }
            }
        }

        #expect(missed == 0, "the fast test missed \(missed) real crossings", sourceLocation: sourceLocation)
        // Guards against the trivial way to pass the above: answering true everywhere. The whole
        // point is that most of the plane is nowhere near the outline.
        #expect(
            claimed < (steps + 1) * (steps + 1) / 2,
            "claimed a crossing almost everywhere, so it saves nothing",
            sourceLocation: sourceLocation
        )
        #expect(truly > 0, "the sweep never crossed the outline", sourceLocation: sourceLocation)
    }

    @Test("A circular outline reports every crossing a small box makes")
    func circularOutline() {
        expectNoMissedCrossings(
            DioramaBoundary.make(shape: .circular, extent: SIMD2(0.8, 0.8)),
            scale: 1,
            extent: 0.6,
            boxSize: 0.01
        )
    }

    @Test("A circular outline reports every crossing a box larger than a grid cell makes")
    func circularOutlineCoarseBoxes() {
        expectNoMissedCrossings(
            DioramaBoundary.make(shape: .circular, extent: SIMD2(0.8, 0.8)),
            scale: 1,
            extent: 0.6,
            boxSize: 0.08
        )
    }

    @Test("A hexagonal outline's long straight edges are still reported")
    func hexagonalOutline() {
        expectNoMissedCrossings(
            DioramaBoundary.make(shape: .hexagonal, extent: SIMD2(0.8, 0.8)),
            scale: 1,
            extent: 0.6,
            boxSize: 0.01
        )
    }

    /// A concave outline is the case where a box can sit inside the outline's bounding box, outside
    /// the outline itself, and still be nowhere near an edge — so the grid has to be driven by the
    /// edges rather than by the bounds.
    @Test("A concave outline reports crossings on both sides of its reflex corners")
    func concaveOutline() {
        let points: [SIMD2<Float>] = (0..<10).map { index in
            let radius: Float = index.isMultiple(of: 2) ? 0.45 : 0.19
            let angle = Float(index) / 10 * 2 * .pi - .pi / 2
            return SIMD2(radius * cos(angle), radius * sin(angle))
        }
        expectNoMissedCrossings(
            DioramaBoundary.make(shape: .custom(points: points), extent: SIMD2(0.8, 0.8)),
            scale: 1,
            extent: 0.6,
            boxSize: 0.01
        )
    }

    /// The prism divides the outline by the scale factor, so the grid has to be built in that same
    /// space. Building it in diorama meters while querying in tile meters would misreport
    /// everything without changing a single vertex.
    @Test("Crossings are reported in the geometry's space, not the outline's")
    func scaledOutline() {
        expectNoMissedCrossings(
            DioramaBoundary.make(shape: .circular, extent: SIMD2(0.8, 0.8)),
            scale: 0.8 / 1400,
            extent: 1050,
            boxSize: 20
        )
    }

    /// Coordinates far enough out to overflow the grid's integer indexing if they were converted
    /// rather than clamped — a real risk, since a stray 3D Tiles child can sit an Earth radius away.
    @Test("A box astronomically far from the outline is answered, not trapped on")
    func farAwayBox() {
        let prism = BoundaryPrism(boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(0.8, 0.8)), scale: 1)
        #expect(prism.mayCrossOutline(SIMD2(-6e12, -6e12), SIMD2(-5.9e12, -5.9e12)) == false)
        #expect(prism.mayCrossOutline(SIMD2(5.9e12, 5.9e12), SIMD2(6e12, 6e12)) == false)
        // Spanning the outline entirely: the outline is inside the box, so it must not be missed.
        #expect(prism.mayCrossOutline(SIMD2(-6e12, -6e12), SIMD2(6e12, 6e12)) == true)
    }

    /// The dead centre of a diorama is the furthest point from the outline there is, and it is
    /// where most of a tile's triangles sit. If this reported a crossing the fast path would never
    /// fire where it matters most.
    @Test("A box in the middle of the outline reports no crossing")
    func interiorBox() {
        let prism = BoundaryPrism(boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(0.8, 0.8)), scale: 1)
        #expect(prism.mayCrossOutline(SIMD2(-0.01, -0.01), SIMD2(0.01, 0.01)) == false)
    }
}
