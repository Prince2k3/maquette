import Testing
import simd
@testable import Maquette

/// Panning on the photorealistic path moves the outline across the streamed model rather than
/// moving the model's vertices, so what these check is the outline's arithmetic: which direction it
/// travels, and which tiles that travel actually changes.
@Suite("3D Tiles panning")
struct Tiles3DPanningTests {
    /// A 100 m square outline centred on the origin, in diorama meters.
    private static func square(offset: SIMD2<Float> = .zero) -> DioramaBoundary {
        DioramaBoundary(vertices: [
            SIMD2(-50, -50), SIMD2(50, -50), SIMD2(50, 50), SIMD2(-50, 50),
        ].map { $0 + offset })
    }

    @Test("Panning moves the outline towards the ground being panned to")
    func outlineTravelsWithTheOffset() {
        let offset = SIMD2<Float>(20, 0)
        let fixed = BoundaryPrism(boundary: Self.square(), scale: 1)
        let panned = BoundaryPrism(boundary: Self.square(offset: offset), scale: 1)

        // Ground 60 m east is outside the fixed outline and inside the panned one: panning east is
        // what brings it into view.
        #expect(!fixed.contains(SIMD2(60, 0)))
        #expect(panned.contains(SIMD2(60, 0)))

        // And ground 60 m west leaves, which is the same statement from the other side.
        #expect(fixed.contains(SIMD2(-40, 0)))
        #expect(!panned.contains(SIMD2(-40, 0)))
    }

    @Test("Scale divides the outline into the geometry's space, offset and all")
    func offsetIsScaledWithTheOutline() {
        // Half a diorama meter per real meter, so a 100 m outline covers 200 m of ground.
        let prism = BoundaryPrism(boundary: Self.square(offset: SIMD2(10, 0)), scale: 0.5)
        #expect(prism.lowerBound.x == -80)
        #expect(prism.upperBound.x == 120)
    }

    @Test("A box is inside, outside, or straddling")
    func containmentClassifiesBoxes() {
        let prism = BoundaryPrism(boundary: Self.square(), scale: 1)

        #expect(prism.containment(of: SIMD2(-10, -10), SIMD2(10, 10)) == .inside)
        #expect(prism.containment(of: SIMD2(100, 100), SIMD2(120, 120)) == .outside)
        #expect(prism.containment(of: SIMD2(40, -10), SIMD2(60, 10)) == .straddling)
    }

    /// The conservative answer is the safe one: a needless `straddling` costs a rebuild, while a
    /// wrong `inside` leaves geometry on screen that the outline should have cut.
    @Test("A concave outline never claims certainty")
    func concaveOutlinesStraddle() {
        // An L, whose reflex corner is exactly what a corner test cannot see past.
        let concave = DioramaBoundary(vertices: [
            SIMD2(-50, -50), SIMD2(50, -50), SIMD2(50, 0),
            SIMD2(0, 0), SIMD2(0, 50), SIMD2(-50, 50),
        ])
        let prism = BoundaryPrism(boundary: concave, scale: 1)
        #expect(prism.pieces.count > 1)

        // Well within the L's lower arm, and still reported as uncertain rather than inside.
        #expect(prism.containment(of: SIMD2(-40, -40), SIMD2(-30, -30)) == .straddling)
        // Clear of the bounding box, which is the one certainty a split outline keeps.
        #expect(prism.containment(of: SIMD2(200, 200), SIMD2(220, 220)) == .outside)
    }

    @Test("Only the tiles the outline's edge crosses are re-cut")
    func recutIsLimitedToTheRim() {
        let before = BoundaryPrism(boundary: Self.square(), scale: 1)
        let after = BoundaryPrism(boundary: Self.square(offset: SIMD2(5, 0)), scale: 1)

        func needsRecut(_ lower: SIMD2<Float>, _ upper: SIMD2<Float>) -> Bool {
            Tiles3DSourceGeometry.needsRecut(lower: lower, upper: upper, from: before, to: after)
        }

        // Deep inside the outline both before and after: the container's transform carries it.
        #expect(!needsRecut(SIMD2(-20, -20), SIMD2(-10, -10)))
        // Far outside both times: nothing to draw either way.
        #expect(!needsRecut(SIMD2(200, 200), SIMD2(220, 220)))
        // On the rim throughout — cut both times, but along a different line.
        #expect(needsRecut(SIMD2(40, -10), SIMD2(60, 10)))
        // Crossed the edge, which is the case that changes what is drawn at all.
        #expect(needsRecut(SIMD2(51, -10), SIMD2(54, 10)))
    }

    /// The column and the clip have to be reading the same outline.
    ///
    /// They are separate mechanisms — one decides what is fetched, the other what survives — and a
    /// column that lagged the outline would cull exactly the tiles about to slide into view, which
    /// looks identical to the stream simply being slow. Deriving the centre from the prism rather
    /// than tracking it alongside is what makes them unable to disagree.
    @Test("The cull column sits at the outline's centre, wherever the pan has put it")
    @MainActor
    func cullColumnIsDerivedFromTheOutline() {
        #expect(Tiles3DLODManager.cullCenter(of: BoundaryPrism(boundary: Self.square(), scale: 1)) == .zero)

        let panned = BoundaryPrism(boundary: Self.square(offset: SIMD2(30, -10)), scale: 1)
        #expect(Tiles3DLODManager.cullCenter(of: panned) == SIMD2(30, -10))

        // Scale divides the outline into the geometry's space, and the column is measured there too.
        let scaled = BoundaryPrism(boundary: Self.square(offset: SIMD2(30, -10)), scale: 0.5)
        #expect(Tiles3DLODManager.cullCenter(of: scaled) == SIMD2(60, -20))

        // No outline, no travel: an unbounded model keeps the column where the diorama was placed.
        #expect(Tiles3DLODManager.cullCenter(of: nil) == .zero)
    }

    @Test("An unbounded model has nothing to re-cut")
    func noPrismMeansNoWork() {
        let prism = BoundaryPrism(boundary: Self.square(), scale: 1)
        #expect(!Tiles3DSourceGeometry.needsRecut(
            lower: SIMD2(-20, -20), upper: SIMD2(-10, -10), from: nil, to: nil
        ))
        // Gaining or losing an outline is a change like any other.
        #expect(Tiles3DSourceGeometry.needsRecut(
            lower: SIMD2(200, 200), upper: SIMD2(220, 220), from: nil, to: prism
        ))
    }

    /// The frontier is where the visible answer stops being trustworthy.
    ///
    /// Panning past streamed geometry does not smear the way clamped height sampling does — tile
    /// vertices never move — but the datum does: it is measured over whatever is on screen, so an
    /// outline standing over empty space measures nothing, and the moment tiles arrive there the
    /// tray and the cut wall move with it.
    @Test("The outline may travel to the edge of the loaded ground and no further")
    func limitsStopAtTheEdgeOfLoadedGround() {
        // 300 m of ground centred on the origin, under a 100 m outline: 100 m of slack each way.
        let limits = Tiles3DPanFrontier.limits(
            groundLow: SIMD2(-150, -150),
            groundHigh: SIMD2(150, 150),
            outline: Self.square()
        )
        #expect(limits.low == SIMD2(-100, -100))
        #expect(limits.high == SIMD2(100, 100))
    }

    /// Ground arrives unevenly, so the two ends of an axis are independent.
    @Test("Ground loaded on one side alone only permits travel that way")
    func limitsFollowLopsidedGround() {
        // Ground reaching 250 m east but only 50 m west of the outline's own edges.
        let limits = Tiles3DPanFrontier.limits(
            groundLow: SIMD2(-100, -150),
            groundHigh: SIMD2(300, 150),
            outline: Self.square()
        )
        #expect(limits.low.x == -50)
        #expect(limits.high.x == 250)
        // The other axis is untouched by that asymmetry.
        #expect(limits.low.y == -100)
        #expect(limits.high.y == 100)
    }

    /// The ordinary state early in a stream, and the one that produces an inverted range.
    ///
    /// Handed back as-is, `simd_clamp` would return whichever bound it reached first — so the model
    /// would snap to one edge of the ground it has rather than sitting on the middle of it.
    @Test("Less ground than the outline covers pins it to the middle rather than inverting")
    func lessGroundThanTheOutlinePinsToTheMiddle() {
        // 40 m of ground, offset east, under a 100 m outline.
        let limits = Tiles3DPanFrontier.limits(
            groundLow: SIMD2(80, -20),
            groundHigh: SIMD2(120, 20),
            outline: Self.square()
        )
        #expect(limits.low.x == limits.high.x)
        #expect(limits.low.y == limits.high.y)
        // The outline's centre lands on the ground's centre: 100 m east, and level on the other axis.
        #expect(limits.low.x == 100)
        #expect(limits.low.y == 0)
    }

    /// A clamp exists to refuse movement, and must never produce it.
    ///
    /// Streaming strands the offset outside its own limits routinely — a refinement round that
    /// retires a coarse ancestor shrinks the measured bounds under a model that has not moved.
    /// Clamping absolutely would haul it back on the next touch of any size, which reads as the
    /// model jumping while the finger barely moved.
    @Test("A stranded offset stays where it is and can only come back")
    func clampNeverProducesMovement() {
        let limits = (low: SIMD2<Float>(-100, -100), high: SIMD2<Float>(100, 100))

        // Ordinary refusal: a drag past the frontier stops at it.
        #expect(Tiles3DPanFrontier.clamp(SIMD2(180, 0), to: limits, current: SIMD2(90, 0)) == SIMD2(100, 0))

        // Stranded 40 m beyond the frontier. A touch that moves nothing must move nothing.
        let stranded = SIMD2<Float>(140, 0)
        #expect(Tiles3DPanFrontier.clamp(stranded, to: limits, current: stranded) == stranded)

        // Further out is still refused, while any movement back is allowed in full — including
        // straight past the frontier and back into the range.
        #expect(Tiles3DPanFrontier.clamp(SIMD2(200, 0), to: limits, current: stranded) == stranded)
        #expect(Tiles3DPanFrontier.clamp(SIMD2(120, 0), to: limits, current: stranded) == SIMD2(120, 0))
        #expect(Tiles3DPanFrontier.clamp(SIMD2(0, 0), to: limits, current: stranded) == SIMD2(0, 0))
    }
}
