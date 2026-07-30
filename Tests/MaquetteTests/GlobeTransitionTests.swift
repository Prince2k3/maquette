import Foundation
import Testing
@testable import Maquette

/// The handoff's invariants.
///
/// The ones worth pinning are all about *continuity*: a transition that arrives at the right place
/// but jumps on the way reads as a bug, and every jump available here is at an endpoint — the frame
/// progress leaves 0, the frame it reaches 1, and the frame the cross-fade hands over.
@Suite("Globe transition")
struct GlobeTransitionTests {
    private let chunkLimits: ClosedRange<Float> = (10 * .pi / 180)...(80 * .pi / 180)

    /// Stands in for what the view measures: the globe's radius and the half-angle of the narrower
    /// screen axis, here a portrait phone's ~19°.
    private let globeRadius: Float = 2
    private let narrowHalfFOV: Float = 19 * .pi / 180

    private func atMaximum(_ transition: inout GlobeTransition, distance: Float = 1.5) {
        // One large zoom-out, taken with the chunk out of room, is enough to reach the globe.
        _ = transition.absorb(zoomDelta: -1000, cameraDistance: distance, cameraElevation: 0.4, chunkHasRoom: false)
    }

    // MARK: - Absorbing input

    @Test("Zooming out is the chunk's until the chunk runs out of room")
    func absorbsOnlyAtTheLimit() {
        var transition = GlobeTransition()
        // Bound to a local rather than inlined: #expect cannot call a mutating member.
        let withRoomLeft = transition.absorb(zoomDelta: -10, cameraDistance: 1.0, cameraElevation: 0.4, chunkHasRoom: true)
        #expect(withRoomLeft.consumed == false)
        #expect(transition.progress == 0)
        let atTheLimit = transition.absorb(zoomDelta: -10, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        #expect(atTheLimit.consumed)
        #expect(transition.progress > 0)
    }

    @Test("Zooming in at the chunk is never the transition's")
    func zoomingInAtRestIsDeclined() {
        var transition = GlobeTransition()
        let absorption = transition.absorb(zoomDelta: 10, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        #expect(absorption.consumed == false)
        #expect(transition.progress == 0)
    }

    @Test("Once started, the transition keeps the gesture in both directions")
    func keepsTheGestureWhileInFlight() {
        var transition = GlobeTransition()
        _ = transition.absorb(zoomDelta: -10, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        let outward = transition.progress
        // Zooming back in is now the transition's, even though the chunk has room again — the chunk
        // is not what the user is looking at.
        let absorption = transition.absorb(zoomDelta: 4, cameraDistance: 0.2, cameraElevation: 0.4, chunkHasRoom: true)
        #expect(absorption.consumed)
        #expect(transition.progress < outward)
    }

    @Test("Progress cannot leave 0...1")
    func progressIsClamped() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        #expect(transition.progress == 1)
        #expect(transition.isGlobeOnly)
        _ = transition.absorb(zoomDelta: 100_000, cameraDistance: 0.1, cameraElevation: 0.4, chunkHasRoom: true)
        #expect(transition.progress == 0)
        #expect(!transition.isShowingGlobe)
    }

    @Test("Handing the gesture back to the camera returns it to where it started")
    func returnsToTheEntryDistance() {
        var transition = GlobeTransition()
        // One small step in: the framing has to continue from where the camera already was, so the
        // check is against the entry distance rather than against a tolerance the sensitivity could
        // grow past.
        _ = transition.absorb(zoomDelta: -1, cameraDistance: 1.4, cameraElevation: 0.4, chunkHasRoom: false)
        let framed = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
        #expect(abs((transition.cameraDistance(globeDistance: framed) ?? 0) - 1.4) < 0.05)
        atMaximum(&transition, distance: 1.4)
        #expect(abs((transition.cameraDistance(globeDistance: framed) ?? 0) - framed) < 1e-4)
        // Zooming all the way back in returns the camera to the distance it left, not to a default.
        _ = transition.absorb(zoomDelta: 100_000, cameraDistance: 0.1, cameraElevation: 0.4, chunkHasRoom: true)
        #expect(abs((transition.cameraDistance(globeDistance: framed) ?? 0) - 1.4) < 1e-4)
    }

    @Test("A reset puts it back at the chunk")
    func resetReturnsToTheChunk() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        transition.reset()
        #expect(transition.progress == 0)
        #expect(!transition.isShowingGlobe)
    }

    // MARK: - Framing

    /// The frame progress leaves 0 on is the one the user is looking at when the handoff starts, so
    /// the framing has to be exactly the chunk's there — not nearly.
    @Test("Framing is the chunk's at progress 0 and the globe's at 1")
    func framingMatchesAtBothEnds() {
        var transition = GlobeTransition()
        let framed = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
        #expect(
            transition.cameraTarget(chunkCenterY: -0.2, globeRadius: globeRadius)
                == SIMD3<Float>(0, -0.2, 0)
        )
        #expect(transition.elevationLimits(chunkRange: chunkLimits) == chunkLimits)

        atMaximum(&transition)
        let target = transition.cameraTarget(chunkCenterY: -0.2, globeRadius: globeRadius)
        #expect(abs(target.y - -globeRadius) < 1e-4)
        #expect(abs((transition.cameraDistance(globeDistance: framed) ?? 0) - framed) < 1e-4)
    }

    /// The defect this replaced: an absolute distance of 3.2 against a radius of 2 left the camera
    /// 1.2 m off the surface, where the sphere spans ~78° and overflows the frame in every
    /// direction. What arrives is an edge-to-edge wall of ocean with no limb on screen, which reads
    /// as a broken texture rather than as a camera standing too close — so the invariant to pin is
    /// the *angle the globe subtends*, not the distance that happens to produce it.
    @Test("The whole world fits inside the frame")
    func theGlobeIsFramedRatherThanPressedAgainst() {
        let transition = GlobeTransition()
        // Every plausible screen: a portrait phone's narrow axis through a square-ish iPad.
        for halfFOV in [15, 19, 24, 30].map({ Float($0) * .pi / 180 }) {
            for radius in [Float(0.5), 2, 8] {
                let distance = transition.globeDistance(radius: radius, halfFieldOfView: halfFOV)
                #expect(distance > radius, "the camera ended up inside the globe")
                let subtended = asin(radius / distance)
                #expect(subtended < halfFOV, "the globe ran off the edge of the screen")
                // And it must actually fill the frame — a globe framed at arm's length is a dot.
                #expect(subtended > halfFOV / 2, "the globe was left too small to read as the world")
            }
        }
    }

    @Test("The camera keeps its own distance until the handoff starts")
    func distanceIsTheCamerasUntilItIsNot() {
        var transition = GlobeTransition()
        #expect(transition.cameraDistance(globeDistance: 8) == nil)
        _ = transition.absorb(zoomDelta: -1, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        #expect(transition.cameraDistance(globeDistance: 8) != nil)
    }

    @Test("Framing moves without a step in it")
    func framingIsContinuous() {
        var transition = GlobeTransition()
        let framed = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
        var previousTarget = transition.cameraTarget(chunkCenterY: -0.2, globeRadius: globeRadius).y
        // The camera's own distance is the baseline: the first step's framing has to continue from
        // where the camera already was, not arrive somewhere near it.
        let entryDistance: Float = 1.5
        var previousDistance = entryDistance
        var biggestTargetStep: Float = 0
        var biggestDistanceStep: Float = 0

        // A hundred steps of the same gesture, from the chunk to the globe.
        for _ in 0..<200 {
            guard transition.absorb(zoomDelta: -1.5, cameraDistance: entryDistance, cameraElevation: 0.4, chunkHasRoom: false).consumed else {
                Issue.record("the transition declined a delta mid-flight")
                return
            }
            let target = transition.cameraTarget(chunkCenterY: -0.2, globeRadius: globeRadius).y
            let distance = try! #require(transition.cameraDistance(globeDistance: framed))
            biggestTargetStep = max(biggestTargetStep, abs(target - previousTarget))
            biggestDistanceStep = max(biggestDistanceStep, abs(distance - previousDistance))
            previousTarget = target
            previousDistance = distance
        }
        #expect(transition.progress > 0.999)
        // Measured as a share of each one's own travel rather than as an absolute: how far the
        // camera retreats depends on the globe's radius and the frame it has to fit inside, so an
        // absolute bound here would be a bound on the framing rather than on its smoothness.
        let targetTravel = abs(-globeRadius - -0.2)
        let distanceTravel = abs(framed - entryDistance)
        #expect(biggestTargetStep / targetTravel < 0.04, "target stepped by \(biggestTargetStep)")
        #expect(biggestDistanceStep / distanceTravel < 0.04, "distance stepped by \(biggestDistanceStep)")
    }

    /// The chunk's clamp keeps the camera off the tabletop; carried onto a sphere unchanged it
    /// would hold the driven tilt ten degrees short of the pole, which is 1,100 km of ground.
    @Test("The tilt range opens up to the poles")
    func elevationLimitsOpenOnTheGlobe() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        let limits = transition.elevationLimits(chunkRange: chunkLimits)
        // The pole itself, so the driven tilt can reach the one camera the dock's geometry works
        // from. It is reachable because ``CameraController`` names a right vector outright there
        // rather than deriving one.
        #expect(limits.lowerBound == -.pi / 2)
        #expect(limits.upperBound == .pi / 2)
    }

    /// The dock puts the chunk's own coordinate at the sphere's top, so straight down is the only
    /// direction along which what the camera faces and what the chunk was cut from are one point.
    /// Off-axis they part by exactly the camera's tilt — measured on a 26° orbit, 64° of arc.
    @Test("The tilt is driven to the pole and lands back where it started")
    func tiltIsDrivenOverheadAndBack() {
        var transition = GlobeTransition()
        let entry: Float = 26 * .pi / 180
        #expect(transition.cameraElevation() == nil, "the camera owns its own tilt until the handoff")

        var previous = entry
        var biggestStep: Float = 0
        while transition.progress < 1 {
            _ = transition.absorb(zoomDelta: -1.5, cameraDistance: 1.5, cameraElevation: entry, chunkHasRoom: false)
            let elevation = try! #require(transition.cameraElevation())
            biggestStep = max(biggestStep, abs(elevation - previous))
            previous = elevation
        }
        #expect(abs(previous - .pi / 2) < 1e-5, "the globe was not seen from overhead")

        // And the whole way back down to the tilt the chunk was left at, without a step in it.
        while transition.progress > 0 {
            _ = transition.absorb(zoomDelta: 1.5, cameraDistance: 0.2, cameraElevation: entry, chunkHasRoom: true)
            let elevation = try! #require(transition.cameraElevation())
            biggestStep = max(biggestStep, abs(elevation - previous))
            previous = elevation
        }
        #expect(abs(previous - entry) < 1e-5, "the chunk came back at a different tilt")
        #expect(biggestStep < 0.05, "tilt jumped by \(biggestStep) rad")
    }

    @Test("The tilt range closes back onto the chunk's own")
    func elevationLimitsCloseOnTheWayIn() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        var previous = transition.elevationLimits(chunkRange: chunkLimits)
        // An extreme tilt taken on the globe, walked back in. Re-clamping every step is what turns
        // this into a walk rather than a snap at the end.
        var elevation: Float = -80 * .pi / 180
        var biggestStep: Float = 0
        while transition.progress > 0 {
            _ = transition.absorb(zoomDelta: 1.5, cameraDistance: 0.2, cameraElevation: 0.4, chunkHasRoom: true)
            let limits = transition.elevationLimits(chunkRange: chunkLimits)
            let clamped = min(max(elevation, limits.lowerBound), limits.upperBound)
            biggestStep = max(biggestStep, abs(clamped - elevation))
            elevation = clamped
            #expect(limits.lowerBound >= previous.lowerBound - 1e-6)
            #expect(limits.upperBound <= previous.upperBound + 1e-6)
            previous = limits
        }
        #expect(previous == chunkLimits)
        #expect(elevation >= chunkLimits.lowerBound - 1e-6)
        // 170° of tilt were given back over the transition; no single frame may take a visible
        // fraction of it.
        #expect(biggestStep < 0.05, "tilt jumped by \(biggestStep) rad")
    }

    /// The handoff starts where the camera runs out of room, so a camera with too much room is a
    /// handoff nobody reaches. Pinned against the pinch that actually has to perform it: the demo's
    /// chunk is 0.8 m and one full-screen pinch moves the orbit about 0.6 m, so the whole zoom-out
    /// has to stay within a couple of them.
    @Test("The orbit runs out of room at a few times the chunk's own size")
    func orbitLimitIsMeasuredAgainstTheChunk() {
        let transition = GlobeTransition()
        let limit = transition.orbitLimit(chunkExtent: 0.8)
        #expect(limit > 0.8, "the camera must be able to pull back off the chunk at all")
        #expect(limit < 4)
        // A degenerate extent must not hand back a limit inside the chunk's own minimum distance.
        #expect(transition.orbitLimit(chunkExtent: -1) == 0)
    }

    // MARK: - The cross-fade

    @Test("Each half is whole at its own end and gone at the other")
    func crossFadeReachesBothEnds() {
        var transition = GlobeTransition()
        #expect(transition.chunkOpacity == 1)
        #expect(transition.globeOpacity == 0)
        atMaximum(&transition)
        #expect(transition.chunkOpacity == 0)
        #expect(transition.globeOpacity == 1)
    }

    /// Two half-opaque objects cover three quarters of the scene between them, so a straight
    /// cross-fade lets the background bleed through the middle. This is the invariant that stops it,
    /// and it caught a first attempt whose ramps grazed rather than overlapped: eased on both sides,
    /// that one left the whole scene at 0.02 at the midpoint.
    @Test("Something is always fully drawn")
    func nothingDipsInTheMiddle() {
        var transition = GlobeTransition()
        var faintest: Float = 1
        var thinnestCoverage: Float = 1
        for _ in 0..<200 {
            _ = transition.absorb(zoomDelta: -1.5, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            let chunk = transition.chunkOpacity
            let globe = transition.globeOpacity
            faintest = min(faintest, max(chunk, globe))
            // What the scene actually covers, compositing one over the other.
            thinnestCoverage = min(thinnestCoverage, 1 - (1 - chunk) * (1 - globe))
        }
        #expect(faintest > 0.999, "the scene dipped to \(faintest)")
        #expect(thinnestCoverage > 0.999, "the background showed through at \(thinnestCoverage)")
    }

    @Test("Neither half fades in the wrong direction")
    func opacitiesAreMonotonic() {
        var transition = GlobeTransition()
        var previousChunk = transition.chunkOpacity
        var previousGlobe = transition.globeOpacity
        for _ in 0..<200 {
            _ = transition.absorb(zoomDelta: -1.5, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            #expect(transition.chunkOpacity <= previousChunk + 1e-6)
            #expect(transition.globeOpacity >= previousGlobe - 1e-6)
            previousChunk = transition.chunkOpacity
            previousGlobe = transition.globeOpacity
        }
    }

    // MARK: - The return leg

    /// The defect the hold exists for: a pinch back in spends progress the whole way down while the
    /// chunk it is fading to is still being fetched, so the globe finishes fading over nothing.
    @Test("The globe stays whole while the ground under it is fetched")
    func holdingKeepsTheGlobeDrawn() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        transition.beginHold()

        // The finger does not stop for the fetch — this is the whole of a pinch back in.
        for _ in 0..<200 {
            _ = transition.absorb(zoomDelta: 1.5, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            #expect(transition.globeOpacity == 1, "the globe faded with no chunk behind it")
            #expect(transition.chunkOpacity == 0)
        }
        #expect(transition.progress == 0, "the pinch's own progress should still have been spent")
        #expect(transition.isHolding)
    }

    @Test("The hand-back runs to the chunk and stops there")
    func handingBackReachesTheChunk() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        transition.beginHold()
        _ = transition.absorb(zoomDelta: 1000, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        transition.endHold()
        #expect(transition.isAnimating)
        #expect(transition.isHolding == false)

        // A frame at a time, at 60 Hz, for twice as long as the hand-back should take.
        var previousChunk = transition.chunkOpacity
        for _ in 0..<Int(GlobeTransition.returnDuration * 120) {
            transition.advance(by: 1.0 / 60)
            #expect(transition.chunkOpacity >= previousChunk - 1e-6, "the chunk faded back out")
            previousChunk = transition.chunkOpacity
        }
        #expect(transition.isAnimating == false)
        #expect(transition.isShowingGlobe == false)
        #expect(transition.chunkOpacity == 1)
        #expect(transition.globeOpacity == 0)
    }

    /// A finger that commits the relocation and then lifts leaves `progress` wherever the gesture
    /// stopped. Since the displayed progress is the greater of the two, a hand-back that ran to
    /// nothing would hand the scene back to *that* — and stall part way down with the rebuilt chunk
    /// and the whole globe drawn at once.
    @Test("The hand-back lands however far the pinch itself got")
    func handingBackLandsFromAPartialPinch() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        transition.beginHold()

        // Enough of a pinch back in to commit the relocation, and no more.
        _ = transition.absorb(zoomDelta: 50, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        #expect(transition.progress > 0, "the pinch was meant to stop part way")

        transition.endHold()
        transition.advance(by: GlobeTransition.returnDuration * 2)
        #expect(transition.isShowingGlobe == false, "the descent stalled where the finger left it")
        #expect(transition.chunkOpacity == 1)
        #expect(transition.globeOpacity == 0)
    }

    /// The camera comes down with the cross-fade rather than after it, because every framing term is
    /// derived from the same displayed progress.
    @Test("The camera descends over the hand-back, not at the end of it")
    func handingBackDrivesTheCamera() {
        var transition = GlobeTransition()
        atMaximum(&transition, distance: 1.5)
        transition.beginHold()
        _ = transition.absorb(zoomDelta: 1000, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)

        let globeDistance = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
        #expect(transition.cameraDistance(globeDistance: globeDistance) == globeDistance)
        #expect(transition.cameraElevation() == .pi / 2)

        transition.endHold()
        transition.advance(by: GlobeTransition.returnDuration / 2)
        let midway = transition.cameraDistance(globeDistance: globeDistance) ?? 0
        #expect(midway < globeDistance, "the camera had not started coming back down")
        #expect((transition.cameraElevation() ?? 0) < .pi / 2, "the tilt had not started unwinding")

        transition.advance(by: GlobeTransition.returnDuration)
        #expect(transition.cameraDistance(globeDistance: globeDistance) == 1.5)
        #expect(transition.cameraElevation() == 0.4)
    }

    /// Pinching out again during a hand-back must not re-record the entry framing: the camera is on
    /// the globe by then, so the transition would learn the globe's own distance as the place the
    /// chunk was left and the return leg would end nowhere near it.
    @Test("Pinching out mid-hand-back keeps the framing it departed from")
    func absorbingDuringAHoldKeepsTheEntryFraming() {
        var transition = GlobeTransition()
        atMaximum(&transition, distance: 1.5)
        transition.beginHold()
        _ = transition.absorb(zoomDelta: 1000, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        transition.endHold()
        transition.advance(by: GlobeTransition.returnDuration / 2)

        // A zoom-out taken at the globe's own framing, which is what the camera is at mid-descent.
        _ = transition.absorb(zoomDelta: -20, cameraDistance: 9.9, cameraElevation: .pi / 2, chunkHasRoom: false)

        let globeDistance = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
        transition.advance(by: GlobeTransition.returnDuration * 2)
        _ = transition.absorb(zoomDelta: 1000, cameraDistance: 9.9, cameraElevation: .pi / 2, chunkHasRoom: false)
        #expect(transition.cameraDistance(globeDistance: globeDistance) == 1.5)
        #expect(transition.cameraElevation() == 0.4)
    }

    /// A rebuild that failed has nothing to hand back to, so dissolving anyway fades the world out
    /// into an empty scene.
    @Test("Abandoning a hold stays on the globe")
    func abandoningAHoldStaysOnTheGlobe() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        transition.beginHold()
        _ = transition.absorb(zoomDelta: 1000, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        transition.abandonHold()
        #expect(transition.isAnimating == false)
        #expect(transition.isHolding == false)
        #expect(transition.globeOpacity == 1)
        #expect(transition.chunkOpacity == 0)
    }

    /// The band the crossfade leaves the chunk invisible in — from about 0.985 up — used to fall
    /// outside `progress >= 1`, so a pinch that stalled there faded the world and relocated nothing.
    @Test("The chunk is spent as soon as it stops being drawn")
    func globeOnlyMatchesWhatIsDrawn() {
        var transition = GlobeTransition()
        for _ in 0..<400 {
            _ = transition.absorb(zoomDelta: -0.5, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            #expect(transition.isGlobeOnly == (transition.chunkOpacity <= 0.001))
        }
        #expect(transition.isGlobeOnly)
    }

    /// The return leg is committed by whichever step first draws the chunk again, and a pinch is
    /// free to make that step as large as it likes: a fast flick reports the whole spread in one
    /// update, which spends the handoff from 1 to 0 without ever passing through the middle.
    @Test("A step that spends the whole handoff still commits the return")
    func oneStepCommitsTheReturn() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        #expect(transition.isGlobeOnly)
        let absorption = transition.absorb(zoomDelta: 1000, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        #expect(transition.progress == 0, "the step was meant to spend the whole range")
        #expect(absorption.consumed)
        #expect(absorption.committedReturn)
    }

    /// Committing is an *edge*, and a relocation is not cancellable — so a second commitment out of
    /// the same return leg would rebuild the chunk twice at whatever the globe had been left on.
    @Test("The return is committed once, by the step that crosses")
    func theReturnIsCommittedOnce() {
        var transition = GlobeTransition()
        // Out to the globe: no step on the way out commits a return.
        for _ in 0..<200 {
            let outward = transition.absorb(zoomDelta: -1.5, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            #expect(outward.committedReturn == false)
        }
        #expect(transition.isGlobeOnly)

        var commitments = 0
        for _ in 0..<200 {
            let inward = transition.absorb(zoomDelta: 1.5, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            if inward.committedReturn { commitments += 1 }
        }
        #expect(commitments == 1)
        #expect(transition.progress == 0)
    }
}
