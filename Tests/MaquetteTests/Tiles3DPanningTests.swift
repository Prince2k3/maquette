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
}
