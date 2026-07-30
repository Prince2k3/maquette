import Foundation
import SwiftUI
import simd

/// How the chunk hands off to the globe, and what the globe looks like when it gets there.
public struct GlobeTransitionStyle: Sendable, Equatable {
    /// The globe's radius in diorama meters.
    ///
    /// Not a true scale and cannot be — see ``GlobeDock``. What it has to be is *comparable to the
    /// distance the camera is at when the handoff starts*, because the camera keeps orbiting through
    /// the transition and its target slides from the origin down to the globe's centre. A globe far
    /// larger than the camera's distance puts the camera almost on the surface, where the orbit's
    /// elevation clamp bites and the handoff jumps.
    public var radius: Float

    /// How much of the frame's narrower half-angle the globe spans once the transition completes.
    ///
    /// A *fraction*, not a distance, because the distance that frames a sphere is not a property of
    /// the sphere — it is the radius divided by the sine of the angle it is asked to subtend, and
    /// that angle belongs to the view. An absolute distance has to be guessed against a field of view
    /// and an aspect ratio it cannot see, and guessing it low is the one failure that does not look
    /// like a framing error: at 3.2 against a radius of 2 the camera sits 1.2 m off the surface, the
    /// sphere spans ~78° of a 60° frame, and the globe arrives as an edge-to-edge wall of ocean with
    /// no limb anywhere on screen. Which reads as a broken texture rather than as a camera too close.
    ///
    /// See ``GlobeTransition/globeDistance(radius:halfFieldOfView:)``.
    public var frameFill: Float

    /// Zoom level the world imagery is fetched at. Sixteen tiles at 2, sixty-four at 3.
    public var imageryZoom: Int

    /// Transition progress gained per unit of zoom delta.
    ///
    /// The delta is the same one ``DioramaGestureType/zoom`` feeds the orbit camera, so this is
    /// calibrated against `CameraController.zoomSensitivity` **and** against ``orbitLimitMultiple``:
    /// at 1/100 the handoff takes about a third of the pinching the chunk's own zoom range does,
    /// which reads as a continuation of the same gesture rather than a separate one.
    public var sensitivity: Float

    /// How far past the chunk's own size the orbit may pull back before the world takes over.
    ///
    /// See ``GlobeTransition/orbitLimit(chunkExtent:)`` for why the camera's own default cannot be
    /// left alone here.
    public var orbitLimitMultiple: Float

    /// Rows and columns of the globe mesh. See ``GlobeGeometry/build(radius:rows:columns:)``.
    public var rows: Int
    public var columns: Int

    public init(
        radius: Float = 2.0,
        frameFill: Float = 0.8,
        imageryZoom: Int = 3,
        sensitivity: Float = 1.0 / 100.0,
        orbitLimitMultiple: Float = 4,
        rows: Int = 128,
        columns: Int = 256
    ) {
        self.radius = radius
        self.frameFill = frameFill
        self.imageryZoom = imageryZoom
        self.sensitivity = sensitivity
        self.orbitLimitMultiple = orbitLimitMultiple
        self.rows = rows
        self.columns = columns
    }
}

/// The zoom-out-to-the-world state machine.
///
/// One number carries the whole transition: `progress`, from 0 at the chunk to 1 at the globe. The
/// camera framing, the cross-fade and which gesture a single touch performs are all *derived* from
/// it rather than tracked beside it, which is what keeps them from disagreeing — a separate
/// "isShowingGlobe" flag is exactly how a dissolve ends up with both halves invisible.
///
/// Progress moves only when the orbit camera cannot: a zoom-out is offered to the camera first and
/// reaches the transition only once the camera is already at `maxDistance`. Pinching back in spends
/// progress down to 0 before the camera resumes. So the handoff has no threshold to cross and no
/// moment where input goes nowhere; the same pinch keeps doing the same thing across it.
///
/// Deliberately platform-agnostic and free of `CameraController`, which does not exist on visionOS.
/// It reports the framing the camera should adopt and the caller applies it.
public struct GlobeTransition: Sendable, Equatable {
    public var style: GlobeTransitionStyle

    /// 0 at the chunk, 1 at the globe.
    public private(set) var progress: Float = 0

    /// Orbit distance the camera held when the transition began, so zooming back in returns to it.
    ///
    /// Nil until a handoff has actually started. There is no sensible stand-in: the transition does
    /// not watch the camera, it is *told* where the camera was at the one moment that matters, and a
    /// zero here would report the camera as sitting inside the chunk.
    private var entryDistance: Float?

    /// Orbit elevation the camera held when the transition began, so zooming back in returns to it.
    private var entryElevation: Float?

    /// The globe carrying the scene on its own, while there is no chunk to hand back to.
    private var hold: Hold?

    private enum Hold: Equatable {
        /// A relocation is in flight. The globe stays whole until the ground under it exists.
        case waiting
        /// The chunk has arrived, and the scene is coming back down to it: 1 → 0.
        case returning(Float)
    }

    public init(style: GlobeTransitionStyle = GlobeTransitionStyle()) {
        self.style = style
    }

    /// The progress everything else is *derived* from: the pinch's own, or the globe's hold over it.
    ///
    /// The two come apart for exactly one reason. A relocation is a full teardown and reload, so for
    /// its whole duration there is no chunk — and the pinch does not stop for it. Taking the greater
    /// of the two is what keeps the globe covering the scene until there is something to hand back
    /// to; see ``beginHold()``.
    public var displayProgress: Float { max(progress, holdProgress ?? 0) }

    private var holdProgress: Float? {
        switch hold {
        case .waiting: 1
        case .returning(let value): value
        case nil: nil
        }
    }

    /// Whether the globe is contributing anything to the scene.
    public var isShowingGlobe: Bool { displayProgress > 0 }

    /// Whether the chunk has gone entirely, so its input no longer means anything.
    ///
    /// Asked of the *drawing* rather than of the number, because the two part company near the top
    /// of the range: easing takes the chunk's opacity to zero at about 0.985, and in that band the
    /// globe is alone on screen while a pinch back in relocates nothing — the world simply fades and
    /// the chunk is still where it was. A continuous pinch normally overshoots and clamps to 1, which
    /// is what kept it rare rather than fixed.
    public var isGlobeOnly: Bool { chunkOpacity <= 0.001 }

    // MARK: - Input

    /// What a zoom delta did to the transition.
    public struct Absorption: Equatable, Sendable {
        /// Whether the transition took the delta and nothing else should also apply it.
        public var consumed: Bool

        /// Whether this is the step that committed the return leg — the globe was alone on screen
        /// and no longer is.
        ///
        /// Reported here rather than left for the caller to spot by sampling ``isGlobeOnly`` either
        /// side of the call, because the edge is a fact about *this* step and a caller that samples
        /// it does so around whatever else it happens to do in between. That is not hypothetical:
        /// the view re-framed the camera between the two samples, and re-framing at zero progress
        /// re-docks the globe onto the chunk's own centre — so a pinch step big enough to spend the
        /// whole handoff at once landed the relocation on the ground it had just overwritten.
        public var committedReturn: Bool

        /// The delta belonged to somebody else.
        static let ignored = Absorption(consumed: false, committedReturn: false)
    }

    /// Offers a zoom delta to the transition, reporting what it did.
    ///
    /// The sign is the orbit camera's: positive zooms in, negative zooms out.
    ///
    /// - Parameters:
    ///   - delta: The zoom delta the gesture produced.
    ///   - cameraDistance: The camera's current orbit distance, which the framing continues from.
    ///   - cameraElevation: The camera's current orbit tilt, which the framing returns to.
    ///   - chunkHasRoom: Whether the chunk can still absorb a zoom-out of its own.
    public mutating func absorb(
        zoomDelta delta: Float,
        cameraDistance: Float,
        cameraElevation: Float,
        chunkHasRoom: Bool
    ) -> Absorption {
        let wasGlobeOnly = isGlobeOnly
        if displayProgress <= 0 {
            // Only a zoom-out the chunk has nothing left for starts the handoff. Anything else is
            // ordinary zooming and belongs to the chunk.
            //
            // What "nothing left" means is the caller's to decide, and it is not the same question
            // on every chunk. A chunk that zooms its *ground* runs out when the map reaches the
            // scale at which a flat cut stops making sense — the camera never enters into it, since
            // it has not moved and the chunk is the same size it always was. A fixed chunk has no
            // map to widen, so there the orbit's own furthest distance is the honest answer.
            guard delta < 0, !chunkHasRoom else { return .ignored }
            entryDistance = cameraDistance
            entryElevation = cameraElevation
        }
        progress = min(max(progress - delta * style.sensitivity, 0), 1)
        return Absorption(consumed: true, committedReturn: wasGlobeOnly && !isGlobeOnly)
    }

    /// Puts the transition back at the chunk, for a caller that is resetting the scene.
    public mutating func reset() {
        progress = 0
        entryDistance = nil
        entryElevation = nil
        hold = nil
    }

    // MARK: - The Return Leg

    /// Holds the globe whole while the chunk beneath it is rebuilt.
    ///
    /// The return leg is not the outbound one reversed, because the thing being faded *to* does not
    /// exist yet: a relocation nils the chunk for the whole fetch, and the pinch carries on
    /// regardless. Spent straight through the cross-fade that way, the globe finishes fading at
    /// progress 0.5 with nothing behind it, the scene goes empty for as long as the ground takes to
    /// arrive, and the rebuilt chunk then appears at full opacity having dissolved from nothing.
    ///
    /// Holding decouples the two clocks. The globe stays whole for as long as the rebuild takes —
    /// which is honest, since the world is what the user is actually looking at — and the hand-back
    /// is then a fixed animation that begins when there is something to animate.
    public mutating func beginHold() {
        hold = .waiting
    }

    /// Whether the globe is carrying the scene on its own, with no chunk under it.
    public var isHolding: Bool {
        if case .waiting = hold { return true }
        return false
    }

    /// Hands the scene back to the chunk, over ``returnDuration``.
    ///
    /// The pinch's own progress is spent here, and that is the whole reason the hand-back lands
    /// anywhere. ``displayProgress`` takes the *greater* of the two, so a hold that decays to nothing
    /// hands the scene back to whatever the finger last left `progress` at — and a finger that
    /// committed the relocation and then lifted leaves it wherever the gesture stopped, not at 0. The
    /// descent then stalls there: measured on a scripted pinch, at about 0.5, which draws the rebuilt
    /// chunk and the whole globe at once with the camera half way between them. A relocation is not
    /// cancellable, so once there is ground to come down to, coming down is no longer the finger's
    /// call.
    public mutating func endHold() {
        guard case .waiting = hold else { return }
        hold = .returning(1)
        progress = 0
    }

    /// Gives up on the hand-back and stays on the globe, for a rebuild that failed.
    ///
    /// Dissolving anyway would fade the world out into nothing, since the chunk the dissolve is for
    /// is the thing that did not load. A whole globe with the failure reported over it is the honest
    /// frame.
    public mutating func abandonHold() {
        hold = nil
        progress = 1
    }

    /// Whether the transition is running an animation of its own and needs ticking.
    public var isAnimating: Bool {
        if case .returning = hold { return true }
        return false
    }

    /// Advances the hand-back.
    ///
    /// - Parameter seconds: Wall-clock time elapsed since the last advance.
    public mutating func advance(by seconds: Float) {
        guard case .returning(let value) = hold else { return }
        let next = value - seconds / Self.returnDuration
        hold = next > 0 ? .returning(next) : nil
    }

    /// How long the scene takes to come back down from the globe to the rebuilt chunk.
    ///
    /// It drives the camera as well as the cross-fade — the framing is derived from
    /// ``displayProgress`` like everything else — so this is how long the descent takes, not just
    /// the fade. Long enough to read as coming back down rather than as a cut, short enough not to
    /// keep a user waiting who has already finished pinching.
    public static let returnDuration: Float = 0.7

    // MARK: - Framing

    /// Where the orbit camera should look, given the height it framed the chunk at.
    ///
    /// Slides from the chunk's own vertical midpoint down the Y axis to the globe's centre, so the
    /// user ends up orbiting the sphere rather than a point on its surface. The docked coordinate
    /// stays between the camera and the centre throughout, which is what makes the place the chunk
    /// was still be the place the globe shows.
    ///
    /// **Both arguments are in the camera's own space, not the diorama's.** The chunk and the globe
    /// are drawn under a scale the camera is not, so a target taken straight from
    /// ``GlobeDock`` — which is defined in diorama metres — points at a sphere that is no longer
    /// there. On a phone the scale is within a percent of 1 and the error is invisible; on an iPad it
    /// is over two, and the camera ends up *inside* the globe with no clue as to why.
    ///
    /// - Parameters:
    ///   - chunkCenterY: The chunk's vertical midpoint, scaled.
    ///   - globeRadius: The globe's radius, scaled — its centre hangs one radius below the origin.
    public func cameraTarget(chunkCenterY: Float, globeRadius: Float) -> SIMD3<Float> {
        SIMD3(0, mix(chunkCenterY, -globeRadius, eased), 0)
    }

    /// How far the orbit should tilt, or nil while the camera still owns it.
    ///
    /// The globe ends up seen from **directly overhead**, which is not a stylistic choice. The
    /// dock puts the chunk's coordinate at the sphere's top, so straight down is the one
    /// direction along which "the point facing the camera" and "the point the chunk was cut from"
    /// are the same point — and the return leg picks its new centre by asking the globe what it is
    /// facing. Seen from anywhere else the two come apart by exactly the camera's own tilt, and
    /// zooming out and straight back in again, without touching the globe, rebuilds the chunk
    /// somewhere the user never chose: measured on a 26° orbit, 64° of arc away, Arizona to the
    /// South Pacific.
    ///
    /// It is also what makes the globe aimable at all. Overhead, the departure point is at the
    /// centre of the screen and stays there, so spinning the world to somewhere else is a matter of
    /// dragging that somewhere into the middle. Off-axis there is nothing on screen marking where
    /// the invisible offset points, so there is nothing to aim with.
    ///
    /// The pole is where an orbit camera's up vector is undefined, which is why the value is exact
    /// rather than a degree short: ``CameraController`` handles the degeneracy by naming a right
    /// vector outright, and a degree of slack here is 111 km of ground — far enough to relocate to.
    public func cameraElevation() -> Float? {
        guard let entryElevation else { return nil }
        return mix(entryElevation, .pi / 2, eased)
    }

    /// How far the orbit camera should sit from that target, or nil while the camera still owns it.
    ///
    /// Only defined once a handoff has begun — before that the camera's distance is the camera's own
    /// business, and the transition has nothing to say about it.
    ///
    /// - Parameter globeDistance: Where the camera ends up, from
    ///   ``globeDistance(radius:halfFieldOfView:)``.
    public func cameraDistance(globeDistance: Float) -> Float? {
        guard let entryDistance else { return nil }
        return mix(entryDistance, globeDistance, eased)
    }

    /// How far from the globe's centre the camera has to be for the whole world to fit on screen.
    ///
    /// A sphere of radius *r* seen from *d* subtends `asin(r / d)`, so framing it to fill a given
    /// share of the frame inverts to `r / sin(share · halfFOV)`. Both arguments are the caller's
    /// because both are the *view's*: the radius is scaled by whatever the entity is drawn at, and
    /// the half-angle is the narrower of the screen's two, which no style can know.
    ///
    /// - Parameters:
    ///   - radius: The globe's radius in the camera's space.
    ///   - halfFieldOfView: Half the camera's field of view across the frame's *narrower* axis, in
    ///     radians. Under-stating it only frames the globe smaller; over-stating it runs the world
    ///     off the edge of the screen, so a caller unsure which axis the projection applies its
    ///     angle to should pass the smaller candidate.
    public func globeDistance(radius: Float, halfFieldOfView: Float) -> Float {
        let subtended = min(max(style.frameFill, 0.01), 0.99) * max(halfFieldOfView, 0.01)
        return radius / sin(min(subtended, .pi / 2 - 0.01))
    }

    /// How far the orbit may tilt, given the range the chunk uses.
    ///
    /// The chunk's clamp keeps the camera off the tabletop and away from the singularity directly
    /// overhead. A sphere has no tabletop, and there the same clamp becomes a limit on the framing
    /// itself: ``cameraElevation()`` drives the orbit to the pole, and a range that stops at the
    /// chunk's 80° would quietly hold it ten degrees short — which is 1,100 km of ground between
    /// where the user is aiming and where the chunk would be cut from. Interpolating the limits
    /// with the transition opens the pole with no threshold to cross, and — because the caller
    /// re-clamps against them every step — walks the tilt back into the chunk's range on the way
    /// in instead of snapping it there at the end.
    public func elevationLimits(chunkRange: ClosedRange<Float>) -> ClosedRange<Float> {
        let limit = Self.globeElevationLimit
        return mix(chunkRange.lowerBound, -limit, eased)...mix(chunkRange.upperBound, limit, eased)
    }

    /// The pole itself. See ``cameraElevation()`` for why it is not a degree short of it.
    private static let globeElevationLimit: Float = .pi / 2

    /// How far the orbit may pull back from a chunk of this size before the handoff begins.
    ///
    /// The handoff has no threshold *because* it starts where the camera runs out of room — so how
    /// much room the camera has is the whole question, and the orbit's own default answer is no use
    /// here. `CameraController.maxDistance` is 10 diorama metres against a chunk of 0.8, which is
    /// twelve times its width away: the chunk is a full stop long before that, and reaching it takes
    /// something like three thousand points of pinching. The handoff would exist and nobody would
    /// ever find it. Measured on the Canyon preset, one full-screen pinch moves the orbit by about
    /// 0.6 m, so the default limit is five pinches of watching a speck get smaller.
    ///
    /// Tying the limit to the chunk instead makes "all the way out" mean what it looks like — the
    /// chunk small enough to read as an object on a table, with the world the obvious next thing —
    /// and puts the whole gesture at about two pinches.
    ///
    /// - Parameter chunkExtent: The chunk's horizontal size, in the same space the camera's distance
    ///   is measured in — so scaled by whatever scale the entity is drawn at.
    public func orbitLimit(chunkExtent: Float) -> Float {
        max(chunkExtent, 0) * style.orbitLimitMultiple
    }

    // MARK: - Cross-fade

    /// The globe arrives over the first half and the chunk leaves over the second, so **one of them
    /// is always fully opaque** and the two are both opaque at the midpoint.
    ///
    /// The obvious construction — fade one out while fading the other in — is wrong here, and wrong
    /// in a way that is worth stating. Two half-opaque objects composited over the scene cover only
    /// three quarters of it, so the background bleeds through the middle of the dissolve and the
    /// whole thing reads as a flicker rather than as one thing becoming another. Overlapping the
    /// ramps this way keeps coverage at 1 throughout.
    ///
    /// It has to be a genuine overlap, not a narrow one: easing is applied to each ramp, and easing
    /// pushes a value towards its endpoints, so two ramps that merely graze each other are *both*
    /// near zero where they meet. An earlier 0.45/0.55 pair left the scene at 0.02 in the middle,
    /// which is very nearly a black frame.
    public var chunkOpacity: Float {
        1 - smoothstep(ramp(displayProgress, from: 0.5, to: 1))
    }

    public var globeOpacity: Float {
        smoothstep(ramp(displayProgress, from: 0, to: 0.5))
    }

    // MARK: - Private

    private var eased: Float { smoothstep(displayProgress) }

    private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    private func ramp(_ value: Float, from low: Float, to high: Float) -> Float {
        guard high > low else { return value >= high ? 1 : 0 }
        return min(max((value - low) / (high - low), 0), 1)
    }

    private func smoothstep(_ t: Float) -> Float {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Modifier

/// View modifier enabling the globe handoff on a diorama.
public struct GlobeTransitionModifier: ViewModifier {
    let style: GlobeTransitionStyle?

    public func body(content: Content) -> some View {
        content.environment(\.globeTransitionStyle, style)
    }
}

extension View {
    /// Lets this diorama zoom out into a globe, and back in somewhere else.
    ///
    /// ```swift
    /// DioramaView(configuration: config)
    ///     .globeTransition()
    /// ```
    ///
    /// Pinching out past the camera's furthest orbit dissolves the chunk into the whole world,
    /// docked so the chunk's own centre is the point facing the camera. Spinning the globe and
    /// pinching back in rebuilds the chunk wherever it was left facing — see
    /// ``DioramaStore/relocate(to:)``.
    ///
    /// Not available on visionOS, which presents a volume rather than orbiting a camera.
    public func globeTransition(_ style: GlobeTransitionStyle = GlobeTransitionStyle()) -> some View {
        modifier(GlobeTransitionModifier(style: style))
    }
}

// MARK: - Environment Key

extension EnvironmentValues {
    @Entry var globeTransitionStyle: GlobeTransitionStyle? = nil
}
