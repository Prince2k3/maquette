import Foundation
import Testing
@testable import Maquette

/// The handoff's invariants.
///
/// The ones worth pinning are all about *continuity*: a transition that arrives at the right place
/// but jumps on the way reads as a bug, and every jump available here is at an endpoint — the frame
/// progress leaves 0, the frame it reaches 1, and the frame the cross-fade hands over.
///
/// The handoff is an animation and a pinch only triggers it, so almost every test here drives
/// ``GlobeTransition/advance(by:)`` at 60 Hz and uses `absorb` once. Where a test does pinch
/// repeatedly, that is the point of the test: input arriving mid-flight must change nothing.
@Suite("Globe transition")
struct GlobeTransitionTests {
    private let chunkLimits: ClosedRange<Float> = (10 * .pi / 180)...(80 * .pi / 180)

    /// Stands in for what the view measures: the globe's radius and the half-angle of the narrower
    /// screen axis, here a portrait phone's ~19°.
    private let globeRadius: Float = 2
    private let narrowHalfFOV: Float = 19 * .pi / 180

    private static let frame: Float = 1.0 / 60

    /// Runs whichever leg is playing to its end, a frame at a time.
    ///
    /// Bounded rather than `while`, so a leg that never settles fails the test that follows instead
    /// of hanging the suite.
    private func play(_ transition: inout GlobeTransition) {
        var frames = 0
        while transition.isAnimating, frames < 600 {
            transition.advance(by: Self.frame)
            frames += 1
        }
    }

    /// Plays part of a leg, a frame at a time.
    ///
    /// A single `advance(by: seconds)` is *not* the same thing and cannot stand in for this: a step
    /// that long is a stall, and ``GlobeTransition/maximumStep`` deliberately refuses to spend it.
    private func play(_ transition: inout GlobeTransition, for seconds: Float) {
        var spent: Float = 0
        while spent < seconds, transition.isAnimating {
            transition.advance(by: Self.frame)
            spent += Self.frame
        }
    }

    /// Triggers the departure and plays it all the way out to the globe.
    private func atMaximum(_ transition: inout GlobeTransition, distance: Float = 1.5, elevation: Float = 0.4) {
        _ = transition.absorb(zoomDelta: -1, cameraDistance: distance, cameraElevation: elevation, chunkHasRoom: false)
        play(&transition)
    }

    // MARK: - Absorbing input

    @Test("Zooming out is the chunk's until the chunk runs out of room")
    func absorbsOnlyAtTheLimit() {
        var transition = GlobeTransition()
        // Bound to a local rather than inlined: #expect cannot call a mutating member.
        let withRoomLeft = transition.absorb(zoomDelta: -10, cameraDistance: 1.0, cameraElevation: 0.4, chunkHasRoom: true)
        #expect(withRoomLeft.consumed == false)
        #expect(transition.isBusy == false)
        #expect(transition.progress == 0)
        let atTheLimit = transition.absorb(zoomDelta: -10, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        #expect(atTheLimit.consumed)
        #expect(transition.isAnimating, "the departure should have started playing")
    }

    @Test("Zooming in at the chunk is never the transition's")
    func zoomingInAtRestIsDeclined() {
        var transition = GlobeTransition()
        let absorption = transition.absorb(zoomDelta: 10, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        #expect(absorption.consumed == false)
        #expect(transition.isBusy == false)
        #expect(transition.progress == 0)
    }

    /// The delta is a trigger, not a quantity: what it decides is whether a leg starts, never how
    /// far along one gets. A handoff whose length depended on how hard the user pinched would stop
    /// wherever they stopped, which is what makes half a chunk over half a globe a resting state.
    @Test("The size of the pinch decides nothing")
    func theDeltaIsOnlyATrigger() {
        var faint = GlobeTransition()
        var hard = GlobeTransition()
        _ = faint.absorb(zoomDelta: -0.01, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        _ = hard.absorb(zoomDelta: -10_000, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        #expect(faint.progress == hard.progress)

        faint.advance(by: Self.frame)
        hard.advance(by: Self.frame)
        #expect(faint.progress == hard.progress)
        #expect(faint.progress > 0, "the departure did not start moving")
    }

    /// The whole of what the user asked for: once it is playing, it plays.
    @Test("The departure runs itself out with no further input")
    func theDepartureRunsItselfOut() {
        var transition = GlobeTransition()
        _ = transition.absorb(zoomDelta: -1, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)

        var previous = transition.progress
        var frames = 0
        while transition.isAnimating, frames < 600 {
            transition.advance(by: Self.frame)
            #expect(transition.progress >= previous, "the departure went backwards")
            previous = transition.progress
            frames += 1
        }
        #expect(transition.progress == 1)
        #expect(transition.isBusy == false, "the leg should have settled rather than kept running")
        // At 60 Hz, near enough the stated duration to be the stated duration.
        #expect(abs(Float(frames) * Self.frame - GlobeTransition.departureDuration) < 2 * Self.frame)
    }

    /// Every gesture that arrives mid-flight is *taken* and then dropped. Taken, because a delta
    /// that fell through would reach the orbit camera or the map and move something the animation is
    /// already driving; dropped, because the animation is not the user's to scrub.
    @Test("Input during a leg is swallowed and changes nothing")
    func inputMidLegChangesNothing() {
        for playedOut in [false, true] {
            var transition = GlobeTransition()
            _ = transition.absorb(zoomDelta: -1, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            if playedOut {
                play(&transition)
                _ = transition.absorb(zoomDelta: 1, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            }
            play(&transition, for: GlobeTransition.departureDuration / 4)

            let before = transition.progress
            for delta in [Float(-1000), -1, 1, 1000] {
                let absorption = transition.absorb(
                    zoomDelta: delta, cameraDistance: 9.9, cameraElevation: .pi / 2, chunkHasRoom: true
                )
                #expect(absorption.consumed, "a mid-flight delta must not fall through to the camera")
                #expect(absorption.committedReturn == false)
            }
            #expect(transition.progress == before, "input scrubbed a leg that was already playing")
        }
    }

    /// A step is wall-clock time, and wall clock counts whatever the app was doing instead of
    /// drawing. The step that matters is the first one after a paused timeline resumes: a driver that
    /// carries its date across a settled scene hands the next leg an elapsed of however long the user
    /// spent looking at the globe, and the leg is spent in a single frame. That is a snap with no
    /// gesture behind it — the very thing the clock was introduced to remove — and it reads to the
    /// user as the pinch deciding, because somebody who cycles the handoff is somebody pinching hard.
    ///
    /// A driver still has to keep its own clock honest. This is what stops the mistake from
    /// destroying the animation when it is made.
    @Test("No single step can cross the handoff, however long the frame took")
    func aStallCannotSpendAWholeLeg() {
        for returning in [false, true] {
            var transition = GlobeTransition()
            _ = transition.absorb(zoomDelta: -1, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            if returning {
                play(&transition)
                _ = transition.absorb(zoomDelta: 1, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            }
            let start = transition.progress
            let duration = returning ? GlobeTransition.returnDuration : GlobeTransition.departureDuration

            // Thirty seconds: a timeline resuming after the scene sat settled for half a minute.
            transition.advance(by: 30)

            #expect(transition.isAnimating, "one stalled frame ended the leg outright")
            #expect(
                abs(transition.progress - start) <= GlobeTransition.maximumStep / duration + 1e-5,
                "a single step spent more travel than the cap allows"
            )

            // Stretched, not skipped — the leg still gets where it is going.
            play(&transition)
            #expect(transition.progress == (returning ? 0 : 1))
            #expect(transition.isBusy == false)
        }
    }

    /// At the globe there is nowhere further out to go, but the delta still cannot be handed back:
    /// the orbit camera would take it and walk itself off the world it is framing.
    @Test("Zooming further out at the globe goes nowhere, quietly")
    func zoomingOutAtTheGlobeIsSwallowed() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        let absorption = transition.absorb(zoomDelta: -1000, cameraDistance: 9.9, cameraElevation: .pi / 2, chunkHasRoom: true)
        #expect(absorption.consumed)
        #expect(absorption.committedReturn == false)
        #expect(transition.progress == 1)
        #expect(transition.isBusy == false)
    }

    @Test("A reset puts it back at the chunk")
    func resetReturnsToTheChunk() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        transition.reset()
        #expect(transition.progress == 0)
        #expect(!transition.isShowingGlobe)
        #expect(transition.isBusy == false)
        #expect(transition.cameraDistance(globeDistance: 8) == nil, "the entry framing outlived the reset")
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

    // MARK: - How the globe arrives

    /// The globe's apparent radius on screen, in radians, at the transition's current progress —
    /// the quantity a viewer actually reads, which is what makes it the one to assert on. A distance
    /// and a scale that both move can trade off against each other without anything visible changing.
    private func apparentRadius(_ transition: GlobeTransition, entry: Float) -> Float {
        let framed = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
        let distance = transition.cameraDistance(globeDistance: framed) ?? entry
        let drawn = globeRadius * transition.globeScale
        #expect(distance > drawn, "the camera was inside the globe at progress \(transition.progress)")
        return asin(min(drawn / distance, 1))
    }

    /// The mid-leg defect, stated as an invariant.
    ///
    /// A globe of radius 2 sitting under a chunk orbited at 3.2 is already around the camera when the
    /// handoff begins, so a leg that only pulls the camera back plays *backwards*: measured on a
    /// 402 × 874 pt phone, the sphere subtended 21.8° against a 14.88° frame half-angle a quarter of
    /// the way out, hung 14.7° off-axis, and shrank into its framing from there. Growing the globe
    /// about its docked point instead is what makes it emerge from the ground the chunk stands on.
    @Test("The globe grows into its frame rather than shrinking into it")
    func theGlobeGrowsIntoItsFrame() {
        // The widest orbit a departure can start from: `orbitLimit` for an 0.8 m chunk.
        let entry: Float = 3.2
        var transition = GlobeTransition()
        _ = transition.absorb(zoomDelta: -1, cameraDistance: entry, cameraElevation: 0.4, chunkHasRoom: false)

        let framed = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
        let settled = asin(globeRadius / framed)

        var previous = apparentRadius(transition, entry: entry)
        #expect(previous < settled / 10, "the globe should emerge from the chunk, not appear whole")

        var frames = 0
        while transition.isAnimating, frames < 600 {
            transition.advance(by: Self.frame)
            let radius = apparentRadius(transition, entry: entry)
            #expect(radius >= previous - 1e-6,
                    "the globe shrank at progress \(transition.progress): \(radius) after \(previous)")
            #expect(radius <= settled + 1e-5,
                    "the globe overflowed its own framing at progress \(transition.progress): \(radius)")
            previous = radius
            frames += 1
        }
        #expect(abs(previous - settled) < 1e-5, "the leg did not land on the framing it settles at")
    }

    /// And it holds from *any* orbit, which is the part that cannot be checked by looking at one
    /// departure. The entry distance is wherever the user left the camera, and the bound
    /// `s·G ≤ entry·(1 − s) + G·s` is satisfied for every `s ≤ 1` at every positive entry — including
    /// one further out than the globe's own framing, where the camera comes inward instead.
    @Test("No orbit the chunk was left at can crop the globe")
    func noEntryOrbitCropsTheGlobe() {
        for entry in [Float(0.4), 1.5, 3.2, 9.0, 30.0] {
            var transition = GlobeTransition()
            _ = transition.absorb(zoomDelta: -1, cameraDistance: entry, cameraElevation: 0.4, chunkHasRoom: false)
            let framed = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
            let settled = asin(globeRadius / framed)
            var frames = 0
            while transition.isAnimating, frames < 600 {
                transition.advance(by: Self.frame)
                #expect(apparentRadius(transition, entry: entry) <= settled + 1e-5,
                        "entry \(entry) overflowed the frame at progress \(transition.progress)")
                frames += 1
            }
        }
    }

    /// The return is the leg the defect was actually caught on — a captured frame mid-descent had the
    /// globe wider than the screen with the chunk a translucent disc floating on it — so it gets its
    /// own test rather than being assumed symmetric.
    @Test("Coming back, the globe shrinks away rather than swelling first")
    func theGlobeShrinksAwayOnTheReturn() {
        let entry: Float = 3.2
        var transition = GlobeTransition()
        atMaximum(&transition, distance: entry)
        let framed = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
        let settled = asin(globeRadius / framed)

        let absorption = transition.absorb(
            zoomDelta: 1, cameraDistance: framed, cameraElevation: .pi / 2, chunkHasRoom: true
        )
        #expect(absorption.committedReturn, "the return did not commit")

        var previous = apparentRadius(transition, entry: entry)
        #expect(abs(previous - settled) < 1e-5, "the return did not start from the settled framing")
        var frames = 0
        while transition.isAnimating, frames < 600 {
            transition.advance(by: Self.frame)
            let radius = apparentRadius(transition, entry: entry)
            #expect(radius <= previous + 1e-6,
                    "the globe swelled at progress \(transition.progress): \(radius) after \(previous)")
            previous = radius
            frames += 1
        }
        #expect(previous < settled / 10, "the globe should shrink back into the chunk, not cut away whole")
    }

    /// The camera aims at where the globe *currently is*, not at where it will end up. The target's
    /// globe term is the scaled sphere's own centre, so the two cannot come apart — aiming a radius
    /// below the origin while the sphere is still a bead there would point the camera under it.
    @Test("The camera aims at the globe it is actually drawing")
    func theTargetTracksTheDrawnGlobe() {
        var transition = GlobeTransition()
        _ = transition.absorb(zoomDelta: -1, cameraDistance: 3.2, cameraElevation: 0.4, chunkHasRoom: false)
        var frames = 0
        while transition.isAnimating, frames < 600 {
            transition.advance(by: Self.frame)
            let target = transition.cameraTarget(chunkCenterY: 0, globeRadius: globeRadius)
            #expect(abs(target.y - -globeRadius * transition.globeScale) < 1e-6)
            frames += 1
        }
    }

    @Test("The camera keeps its own distance until the handoff starts")
    func distanceIsTheCamerasUntilItIsNot() {
        var transition = GlobeTransition()
        #expect(transition.cameraDistance(globeDistance: 8) == nil)
        _ = transition.absorb(zoomDelta: -1, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        #expect(transition.cameraDistance(globeDistance: 8) != nil)
    }

    @Test("Handing the gesture back to the camera returns it to where it started")
    func returnsToTheEntryDistance() {
        var transition = GlobeTransition()
        let entry: Float = 1.4
        // The first frame's framing has to continue from where the camera already was, so the check
        // is against the entry distance rather than against a tolerance the duration could grow past.
        _ = transition.absorb(zoomDelta: -1, cameraDistance: entry, cameraElevation: 0.4, chunkHasRoom: false)
        let framed = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
        transition.advance(by: Self.frame)
        #expect(abs((transition.cameraDistance(globeDistance: framed) ?? 0) - entry) < 0.05)

        play(&transition)
        #expect(abs((transition.cameraDistance(globeDistance: framed) ?? 0) - framed) < 1e-4)

        // Coming all the way back in returns the camera to the distance it left, not to a default.
        _ = transition.absorb(zoomDelta: 1, cameraDistance: 9.9, cameraElevation: .pi / 2, chunkHasRoom: true)
        play(&transition)
        #expect(abs((transition.cameraDistance(globeDistance: framed) ?? 0) - entry) < 1e-4)
    }

    @Test("Framing moves without a step in it")
    func framingIsContinuous() {
        var transition = GlobeTransition()
        let framed = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
        var previousTarget = transition.cameraTarget(chunkCenterY: -0.2, globeRadius: globeRadius).y
        let entryDistance: Float = 1.5
        var previousDistance = entryDistance
        var biggestTargetStep: Float = 0
        var biggestDistanceStep: Float = 0

        _ = transition.absorb(zoomDelta: -1, cameraDistance: entryDistance, cameraElevation: 0.4, chunkHasRoom: false)
        var frames = 0
        while transition.isAnimating, frames < 600 {
            transition.advance(by: Self.frame)
            let target = transition.cameraTarget(chunkCenterY: -0.2, globeRadius: globeRadius).y
            let distance = try! #require(transition.cameraDistance(globeDistance: framed))
            biggestTargetStep = max(biggestTargetStep, abs(target - previousTarget))
            biggestDistanceStep = max(biggestDistanceStep, abs(distance - previousDistance))
            previousTarget = target
            previousDistance = distance
            frames += 1
        }
        #expect(transition.progress == 1)
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
        func follow(_ transition: inout GlobeTransition) {
            var frames = 0
            while transition.isAnimating, frames < 600 {
                transition.advance(by: Self.frame)
                let elevation = try! #require(transition.cameraElevation())
                biggestStep = max(biggestStep, abs(elevation - previous))
                previous = elevation
                frames += 1
            }
        }

        _ = transition.absorb(zoomDelta: -1, cameraDistance: 1.5, cameraElevation: entry, chunkHasRoom: false)
        follow(&transition)
        #expect(abs(previous - .pi / 2) < 1e-5, "the globe was not seen from overhead")

        // And the whole way back down to the tilt the chunk was left at, without a step in it.
        _ = transition.absorb(zoomDelta: 1, cameraDistance: 9.9, cameraElevation: .pi / 2, chunkHasRoom: true)
        follow(&transition)
        #expect(abs(previous - entry) < 1e-5, "the chunk came back at a different tilt")
        // A share of the journey rather than an absolute: 64° of arc are covered over the shorter of
        // the two legs, and eased, so a frame's honest maximum is about 3.6% of it.
        #expect(biggestStep / abs(.pi / 2 - entry) < 0.06, "tilt jumped by \(biggestStep) rad")
    }

    @Test("The tilt range closes back onto the chunk's own")
    func elevationLimitsCloseOnTheWayIn() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        var previous = transition.elevationLimits(chunkRange: chunkLimits)
        // An extreme tilt taken on the globe, walked back in. Re-clamping every frame is what turns
        // this into a walk rather than a snap at the end.
        var elevation: Float = -80 * .pi / 180
        let start = elevation
        var biggestStep: Float = 0

        _ = transition.absorb(zoomDelta: 1, cameraDistance: 9.9, cameraElevation: .pi / 2, chunkHasRoom: true)
        var frames = 0
        while transition.isAnimating, frames < 600 {
            transition.advance(by: Self.frame)
            let limits = transition.elevationLimits(chunkRange: chunkLimits)
            let clamped = min(max(elevation, limits.lowerBound), limits.upperBound)
            biggestStep = max(biggestStep, abs(clamped - elevation))
            elevation = clamped
            #expect(limits.lowerBound >= previous.lowerBound - 1e-6)
            #expect(limits.upperBound <= previous.upperBound + 1e-6)
            previous = limits
            frames += 1
        }
        #expect(previous == chunkLimits)
        #expect(elevation >= chunkLimits.lowerBound - 1e-6)
        // The tilt is dragged 90° back into range over the return leg; no single frame may take a
        // visible fraction of it.
        #expect(biggestStep / abs(chunkLimits.lowerBound - start) < 0.06, "tilt jumped by \(biggestStep) rad")
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
        _ = transition.absorb(zoomDelta: -1, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        var frames = 0
        while transition.isAnimating, frames < 600 {
            transition.advance(by: Self.frame)
            let chunk = transition.chunkOpacity
            let globe = transition.globeOpacity
            faintest = min(faintest, max(chunk, globe))
            // What the scene actually covers, compositing one over the other.
            thinnestCoverage = min(thinnestCoverage, 1 - (1 - chunk) * (1 - globe))
            frames += 1
        }
        #expect(faintest > 0.999, "the scene dipped to \(faintest)")
        #expect(thinnestCoverage > 0.999, "the background showed through at \(thinnestCoverage)")
    }

    @Test("Neither half fades in the wrong direction")
    func opacitiesAreMonotonic() {
        var transition = GlobeTransition()
        var previousChunk = transition.chunkOpacity
        var previousGlobe = transition.globeOpacity
        _ = transition.absorb(zoomDelta: -1, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        var frames = 0
        while transition.isAnimating, frames < 600 {
            transition.advance(by: Self.frame)
            #expect(transition.chunkOpacity <= previousChunk + 1e-6)
            #expect(transition.globeOpacity >= previousGlobe - 1e-6)
            previousChunk = transition.chunkOpacity
            previousGlobe = transition.globeOpacity
            frames += 1
        }
    }

    // MARK: - The return leg

    /// The defect the hold exists for: the chunk being faded *to* does not exist yet, because a
    /// relocation nils it for the whole fetch. Run straight into the cross-fade, the globe finishes
    /// fading half way through the fetch and the scene goes empty.
    @Test("The globe stays whole while the ground under it is fetched")
    func holdingKeepsTheGlobeDrawn() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        transition.beginHold()
        #expect(transition.isHolding)
        #expect(transition.isAnimating == false, "nothing moves during the wait; there is nothing to tick")

        // The finger does not stop for the fetch, and neither does the clock.
        for _ in 0..<200 {
            _ = transition.absorb(zoomDelta: 1.5, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            transition.advance(by: Self.frame)
            #expect(transition.globeOpacity == 1, "the globe faded with no chunk behind it")
            #expect(transition.chunkOpacity == 0)
        }
        #expect(transition.progress == 1)
        #expect(transition.isHolding)
    }

    @Test("The hand-back runs to the chunk and stops there")
    func handingBackReachesTheChunk() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        transition.beginHold()
        transition.endHold()
        #expect(transition.isAnimating)
        #expect(transition.isHolding == false)

        // A frame at a time, at 60 Hz, for twice as long as the hand-back should take.
        var previousChunk = transition.chunkOpacity
        for _ in 0..<Int(GlobeTransition.returnDuration * 120) {
            transition.advance(by: Self.frame)
            #expect(transition.chunkOpacity >= previousChunk - 1e-6, "the chunk faded back out")
            previousChunk = transition.chunkOpacity
        }
        #expect(transition.isAnimating == false)
        #expect(transition.isShowingGlobe == false)
        #expect(transition.chunkOpacity == 1)
        #expect(transition.globeOpacity == 0)
    }

    /// However long the fetch took and however much pinching happened over it, the descent starts
    /// from a whole globe. A hand-back that began from wherever a finger had got to would stall part
    /// way down, with the rebuilt chunk and the whole globe drawn at once.
    @Test("The hand-back always starts from a whole globe")
    func handingBackStartsWhole() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        transition.beginHold()
        for _ in 0..<50 {
            _ = transition.absorb(zoomDelta: 50, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        }
        #expect(transition.progress == 1, "the pinch spent progress the hold was meant to hold")

        transition.endHold()
        #expect(transition.globeOpacity == 1)
        play(&transition)
        #expect(transition.isShowingGlobe == false, "the descent stalled short of the chunk")
        #expect(transition.chunkOpacity == 1)
        #expect(transition.globeOpacity == 0)
    }

    /// The camera comes down with the cross-fade rather than after it, because every framing term is
    /// derived from the same progress.
    @Test("The camera descends over the hand-back, not at the end of it")
    func handingBackDrivesTheCamera() {
        var transition = GlobeTransition()
        atMaximum(&transition, distance: 1.5)
        transition.beginHold()

        let globeDistance = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
        #expect(transition.cameraDistance(globeDistance: globeDistance) == globeDistance)
        #expect(transition.cameraElevation() == .pi / 2)

        transition.endHold()
        play(&transition, for: GlobeTransition.returnDuration / 2)
        let midway = transition.cameraDistance(globeDistance: globeDistance) ?? 0
        #expect(midway < globeDistance, "the camera had not started coming back down")
        #expect((transition.cameraElevation() ?? 0) < .pi / 2, "the tilt had not started unwinding")

        play(&transition)
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
        transition.endHold()
        play(&transition, for: GlobeTransition.returnDuration / 2)

        // A zoom-out taken at the globe's own framing, which is what the camera is at mid-descent.
        _ = transition.absorb(zoomDelta: -20, cameraDistance: 9.9, cameraElevation: .pi / 2, chunkHasRoom: false)

        let globeDistance = transition.globeDistance(radius: globeRadius, halfFieldOfView: narrowHalfFOV)
        play(&transition)
        #expect(transition.cameraDistance(globeDistance: globeDistance) == 1.5)
        #expect(transition.cameraElevation() == 0.4)
    }

    /// A rebuild that failed has nothing to hand back to, so dissolving anyway fades the world out
    /// into an empty scene. It settles rather than staying busy, so the user can pinch again.
    @Test("Abandoning a hold stays on the globe")
    func abandoningAHoldStaysOnTheGlobe() {
        var transition = GlobeTransition()
        atMaximum(&transition)
        transition.beginHold()
        transition.abandonHold()
        #expect(transition.isAnimating == false)
        #expect(transition.isHolding == false)
        #expect(transition.isBusy == false)
        #expect(transition.globeOpacity == 1)
        #expect(transition.chunkOpacity == 0)
    }

    /// "Settled at the globe" and "the chunk is not drawn" have to be the same moment. Under a
    /// pinch-driven handoff they were not: the cross-fade leaves the chunk invisible from about
    /// 0.985 up, so a pinch that stalled in that band faded the world and relocated nothing.
    @Test("The chunk is gone exactly when the departure settles")
    func settlingAtTheGlobeMeansTheChunkIsGone() {
        var transition = GlobeTransition()
        _ = transition.absorb(zoomDelta: -1, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        var frames = 0
        while transition.isAnimating, frames < 600 {
            transition.advance(by: Self.frame)
            frames += 1
        }
        #expect(transition.progress == 1)
        #expect(transition.chunkOpacity == 0)
        #expect(transition.isBusy == false)
    }

    /// Committing is an *edge*, and a relocation is not cancellable — so a second commitment out of
    /// the same return leg would rebuild the chunk twice at whatever the globe had been left on.
    @Test("The return is committed once, by the pinch that starts it")
    func theReturnIsCommittedOnce() {
        var transition = GlobeTransition()
        // Out to the globe: nothing on the way out commits a return.
        _ = transition.absorb(zoomDelta: -1, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
        var commitments = 0
        var frames = 0
        while transition.isAnimating, frames < 600 {
            let outward = transition.absorb(zoomDelta: -1.5, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            #expect(outward.committedReturn == false)
            transition.advance(by: Self.frame)
            frames += 1
        }

        // And back: exactly one of the whole run of pinches is the one that starts the descent.
        frames = 0
        repeat {
            let inward = transition.absorb(zoomDelta: 1.5, cameraDistance: 1.5, cameraElevation: 0.4, chunkHasRoom: false)
            if inward.committedReturn { commitments += 1 }
            transition.advance(by: Self.frame)
            frames += 1
        } while transition.isAnimating && frames < 600
        #expect(commitments == 1)
        #expect(transition.progress == 0)
    }
}
