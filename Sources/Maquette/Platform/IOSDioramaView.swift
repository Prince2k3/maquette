#if os(iOS)
import SwiftUI
import RealityKit
import os

/// iOS presentation of the diorama with embedded RealityView and touch gestures.
///
/// Uses a `CameraController` for orbit camera and touch gesture handling:
/// - Single finger drag → rotate orbit camera
/// - Pinch → zoom
/// - Two-finger pan → translate
struct IOSDioramaView: View {
    let configuration: DioramaConfiguration
    let content: DioramaContentGroup?

    @State private var store: DioramaStore
    @State private var cameraController = CameraController()
    @State private var dragTracker = MultitouchDragTracker()
    @State private var viewSize: CGSize = CGSize(width: 400, height: 400)
    @State private var lastAnimationDate: Date?
    @State private var transition = GlobeTransition()
    private let logger = Logger(subsystem: "com.maquette", category: "IOSDioramaView")
    /// The transition's own animation clock, kept apart from the route preview's: the two run
    /// independently and sharing one date would have each of them consuming the other's elapsed time.
    @State private var lastTransitionDate: Date?
    @State private var legStart: Date?
    @State private var legSteps = 0
    @State private var chunkCenterY: Float = 0
    /// The orbit's own tilt range, captured before the transition starts widening it.
    @State private var chunkElevationLimits: ClosedRange<Float> = 0...0

    @Environment(\.routePreviewController) private var routePreviewController
    @Environment(\.enabledDioramaGestures) private var enabledGestures
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dioramaEffect) private var effect
    @Environment(\.globeTransitionStyle) private var globeStyle

    init(configuration: DioramaConfiguration, content: DioramaContentGroup?) {
        self.configuration = configuration
        self.content = content
        self._store = State(initialValue: DioramaStore(configuration: configuration))
    }

    var body: some View {
        GeometryReader { geometry in
            realityContent
                .onAppear {
                    viewSize = geometry.size
                    updateEntityScale()
                }
                .onChange(of: geometry.size) { _, newSize in
                    viewSize = newSize
                    updateEntityScale()
                }
        }
        // An effect that draws its own light needs darkness behind it, or the contours are no
        // longer the brightest thing on screen.
        .background(effect.backgroundColor ?? .clear)
        .dioramaLoadingOverlay(
            state: overlayState,
            streamingProgress: store.streamingProgress
        ) {
            store.reset()
            Task {
                await store.load()
                store.applyContent(content)
                frameLoadedChunk()
            }
        }
        .task(id: globeStyle) {
            guard let globeStyle else { return }
            transition.style = globeStyle
            applyOrbitLimit()
            await store.loadGlobe(style: globeStyle)
        }
        .task {
            if let elevation = configuration.cameraElevation {
                cameraController.elevation = elevation
            }
            if let distance = configuration.cameraDistance {
                cameraController.distance = distance
            }
            chunkElevationLimits = cameraController.minElevation...cameraController.maxElevation
            store.setEffect(effect)
            await store.load()
            store.applyContent(content)
            frameLoadedChunk()
        }
        .onChange(of: effect) { _, newEffect in
            store.setEffect(newEffect)
        }
        .onChange(of: configuration.buildings?.isVisible) { _, isVisible in
            store.setBuildingsVisible(isVisible ?? false)
        }
        .onChange(of: routePreviewController?.playbackState) { _, newState in
            RouteAnimationHelper.handlePlaybackStateChange(
                newState,
                cameraController: cameraController,
                routeEntity: store.routePreviewEntity,
                lastAnimationDate: &lastAnimationDate
            )
        }
    }

    /// Points the orbit camera at the chunk's vertical midpoint.
    ///
    /// The chunk hangs below Y = 0 by its base depth, so orbiting the origin would frame it high.
    private func frameLoadedChunk() {
        guard let entity = store.dioramaEntity as? DioramaEntity else { return }
        chunkCenterY = entity.verticalCenter
        // A chunk arriving mid-handoff must not pull the camera back to it: the transition owns the
        // framing until it is finished, and a relocated chunk finishes loading in the middle of one.
        guard !transition.isShowingGlobe else { return }
        // Scaled, because the camera is not: the chunk is drawn under `entityScale` and its midpoint
        // has to be read in the space the camera measures its own distance in. This is also the
        // transition's framing at progress 0, and the two disagreeing is a jump on the first step.
        cameraController.target.y = chunkCenterY * entityScale
    }

    /// Pulls the orbit's furthest distance in to the chunk, so zooming out reaches the world.
    ///
    /// Only when a globe is on offer: without one the camera's own range is what the caller asked
    /// for, and narrowing it would take zoom away from a diorama that has nowhere else to go.
    private func applyOrbitLimit() {
        guard globeStyle != nil else { return }
        let extent = store.configuration.horizontalExtent
        cameraController.maxDistance = transition.orbitLimit(
            chunkExtent: max(extent.x, extent.y) * entityScale
        )
    }

    /// Suppresses the loading spinner while the globe is carrying the scene.
    ///
    /// A relocate tears the chunk down and rebuilds it, and the world is what the user is looking at
    /// throughout — a spinner over it would report as missing something that is plainly there. A
    /// failure still surfaces, because a globe cannot say that the ground under it did not load.
    private var overlayState: DioramaLoadingState {
        if transition.isShowingGlobe, case .loading = store.loadingState { return .loaded }
        return store.loadingState
    }

    /// Scale applied to the diorama entity so it fills the available view.
    private var entityScale: Float {
        Float(min(viewSize.width, viewSize.height) / 400.0)
    }

    private func updateEntityScale() {
        store.dioramaEntity?.scale = SIMD3<Float>(repeating: entityScale)
        // The globe takes the same scale about the same origin, or the dock stops meaning anything:
        // it is defined in diorama meters and the chunk it has to line up with is scaled.
        store.globe?.scale = SIMD3<Float>(repeating: entityScale)
        applyOrbitLimit()
    }

    @ViewBuilder
    private var realityContent: some View {
        let needsAnimation = routePreviewController?.playbackState == .playing
            || cameraController.routeFollowPhase == .exiting
            || transition.isAnimating
        TimelineView(.animation(paused: !needsAnimation)) { timeline in
            realityView()
                .onChange(of: timeline.date) { _, newDate in
                    advanceAnimation(at: newDate)
                }
        }
    }

    private func advanceAnimation(at date: Date) {
        advanceTransition(at: date)
        guard let controller = routePreviewController else { return }
        RouteAnimationHelper.advanceAnimation(
            at: date,
            controller: controller,
            routeEntity: store.routePreviewEntity,
            cameraController: cameraController,
            lastAnimationDate: &lastAnimationDate
        )
    }

    private func realityView() -> some View {
        RealityView { content in
            let camera = PerspectiveCamera()
            camera.name = "OrbitCamera"
            camera.camera.fieldOfViewInDegrees = 60
            content.add(camera)

            let sunLight = DirectionalLight()
            sunLight.name = "SunLight"
            sunLight.light.intensity = 1200
            sunLight.light.color = .white
            sunLight.shadow = .init()
            sunLight.look(at: .zero, from: SIMD3<Float>(-0.5, 1.0, -0.3), relativeTo: nil)
            content.add(sunLight)

            let fillLight = PointLight()
            fillLight.name = "FillLight"
            fillLight.light.intensity = 300
            fillLight.light.color = .white
            fillLight.light.attenuationRadius = 5.0
            fillLight.position = SIMD3<Float>(0.5, 0.8, 0.5)
            content.add(fillLight)

            if let entity = store.dioramaEntity {
                content.add(entity)
            }
        } update: { content in
            if let camera = content.entities.first(where: { $0.name == "OrbitCamera" }) {
                camera.transform = cameraController.cameraTransform
            }

            // Matched on identity, not on the name: the store builds a *fresh* entity on every
            // load, and a relocation off the globe is a load. Asking only whether something called
            // "Maquette" is in the scene leaves the old chunk on screen forever while the new one
            // renders nowhere — and because the crossfade left an `OpacityComponent` behind on it,
            // it reads as a dim frozen diorama rather than as a stale one.
            if let entity = store.dioramaEntity {
                let drawn = content.entities.first { $0.name == "Maquette" }
                if drawn !== entity {
                    if let drawn { content.remove(drawn) }
                    content.add(entity)
                    updateEntityScale()
                }
            } else if let drawn = content.entities.first(where: { $0.name == "Maquette" }) {
                // A relocation nils the store's entity for the whole rebuild. Left drawn, the chunk
                // that is being replaced goes on rendering the *old* ground at whatever opacity the
                // crossfade last set — which is what made the return leg read as a stale, dim
                // diorama sitting under the globe rather than as ground being fetched.
                content.remove(drawn)
            }

            if let globe = store.globe {
                let drawn = content.entities.first { $0.name == "Globe" }
                if drawn !== globe {
                    if let drawn { content.remove(drawn) }
                    content.add(globe)
                    updateEntityScale()
                }
            }

            applyTransitionVisibility()

            // Drive 3D Tiles LOD updates from camera position changes. Screen-space error is
            // measured in pixels, so the view's height has to be converted out of points first —
            // passing points asks for a third of the detail on a 3× display, which reads as a
            // model that never sharpens.
            if let tiles3D = (store.dioramaEntity as? DioramaEntity)?.tiles3D {
                tiles3D.requestLODUpdate(
                    cameraPosition: cameraController.cameraPosition,
                    screenHeight: Float(viewSize.height * displayScale),
                    fov: 60 * .pi / 180
                )
            }
        }
        // One gesture handles everything, so pan, orbit, and zoom never contend for the same
        // touches: one finger slides the ground, two orbit the camera and pinch to zoom.
        .gesture(
            SpatialEventGesture(coordinateSpace: .local)
                .onChanged { events in
                    let active = events.filter { $0.phase == .active }
                    // The touches' own timestamps, not the delivery's: the point of carrying them is
                    // that when a touch was sampled and when its frame runs are different questions.
                    let update = dragTracker.update(
                        with: active.map(\.location),
                        at: active.map(\.timestamp).max()
                    )
                    guard let update else { return }
                    apply(update)
                }
                .onEnded { _ in
                    dragTracker.reset()
                }
        )
    }

    /// Routes a multitouch update to panning, orbiting, and zooming.
    ///
    /// A single touch slides the terrain, matching how a map behaves. When the chunk cannot pan —
    /// either the caller disabled it or the configuration set no pan range — a single touch orbits
    /// instead, so a fixed diorama still responds the way it always has.
    private func apply(_ update: MultitouchDragTracker.Update) {
        // The handoff is an animation, and while it plays it owns the camera, the crossfade and the
        // dock alike. A drag admitted here would fight all three: steering during the wait spins the
        // world away from the ground already being fetched for it, and a rotate during either leg
        // pulls against a tilt the transition is driving to a specific angle.
        guard !transition.isBusy else { return }

        let dx = Float(update.translation.width)
        let dy = Float(update.translation.height)

        if update.touchCount == 1 {
            // The globe has no ground to slide, so one finger spins it — which is also what one
            // finger does on a chunk that cannot pan.
            if transition.isShowingGlobe {
                if enabledGestures.contains(.rotate) {
                    steerGlobe(dx: dx, dy: dy)
                }
                return
            }
            if canPanTerrain {
                store.pan(
                    by: cameraController.terrainPanDelta(
                        dragDeltaX: dx,
                        dragDeltaY: dy,
                        viewHeight: Float(viewSize.height),
                        entityScale: entityScale
                    ),
                    at: update.time
                )
            } else if enabledGestures.contains(.rotate) {
                cameraController.rotate(deltaX: dx, deltaY: dy)
            }
            return
        }

        if enabledGestures.contains(.rotate) {
            cameraController.rotate(deltaX: dx, deltaY: dy)
        }
        if enabledGestures.contains(.zoom), update.spreadChange != 0 {
            zoom(by: Float(update.spreadChange) * Self.pinchZoomScale)
        } else if transition.isShowingGlobe {
            applyTransitionFraming()
        }
    }

    /// Whether a single touch should slide the terrain rather than orbit.
    private var canPanTerrain: Bool {
        guard enabledGestures.contains(.pan) else { return false }
        let root = store.dioramaEntity as? DioramaEntity
        return root?.terrain?.canPan == true || root?.tiles3D?.canPan == true
    }

    /// Converts the change in touch spread, in points, into a zoom delta.
    private static let pinchZoomScale: Float = 0.3

    /// Doublings of ground coverage per unit of zoom delta.
    ///
    /// Zoom is multiplicative — a step has to *scale* the ground rather than add to it, or the same
    /// pinch crawls when the chunk is a city and leaps when it is a continent.
    ///
    /// **Calibrate it against the whole ladder, and measure the ladder rather than deriving it.** A
    /// pinch's own quantity is ``MultitouchDragTracker``'s *spread*, which is the mean distance from
    /// the touches' midpoint — half the separation between two fingers, not the separation. So a
    /// full-width pinch on a 402 pt screen is about 170 pt of spread and not 340, and a rate that
    /// reads right per point is out by two over the gesture. It was: at `1/45` this gave
    /// `170 · 0.3 / 45` ≈ **one doubling per full-width pinch**, against the eight doublings
    /// ``DioramaStore/groundScaleLimits`` spans from a chunk loaded at z12 down to
    /// ``DioramaStore/worldTileZoom``. Measured on device that was **nine full-width pinches** to
    /// reach the globe at all — a handoff most people would never find, and nobody who found it
    /// would use twice.
    ///
    /// At 0.08 the same pinch is about **four doublings**, which puts the run from a valley to the
    /// globe at two or three of them, and the return at the same: ``DioramaStore/relocate(to:)``
    /// hands the rebuilt chunk back at the scale it departed from, so the way home is the way out
    /// reversed.
    private static let groundZoomOctaves: Float = 0.08

    /// Half the orbit camera's field of view, matching the `PerspectiveCamera` set up in
    /// ``realityView()``.
    private static let halfFieldOfView: Float = 30 * .pi / 180

    // MARK: - Globe framing

    /// The globe's radius in the camera's space rather than the diorama's.
    private var globeRadiusInView: Float {
        (store.globe?.radius ?? globeStyle?.radius ?? 0) * entityScale
    }

    /// Where the camera has to stand for the whole world to fit inside the frame.
    ///
    /// Framed against the *narrower* of the screen's two half-angles, which in portrait is the
    /// horizontal one and is a good deal tighter than the 60° the camera is configured with: at
    /// 402 × 674 points that is 19°, not 30°. Framing against the wider axis instead is how a globe
    /// ends up correctly distanced and still running off both sides of the screen.
    ///
    /// The camera's angle is taken as the vertical one, which is what `terrainPanDelta` assumes as
    /// well. If the projection applies it horizontally instead, then the true narrow half-angle is
    /// wider than this and the globe simply sits a little smaller in the frame — the error cannot
    /// crop it.
    private var globeDistanceInView: Float {
        let vertical = Self.halfFieldOfView
        let aspect = viewSize.height > 0 ? Float(viewSize.width / viewSize.height) : 1
        let horizontal = atan(tan(vertical) * aspect)
        return transition.globeDistance(
            radius: globeRadiusInView,
            halfFieldOfView: min(vertical, horizontal)
        )
    }

    /// Spins the world under the camera by a drag, one screen point to one point of ground.
    ///
    /// The arc a point of screen covers is measured at the *near* surface rather than at the
    /// globe's centre, because that is the ground being dragged; measured at the centre the world
    /// would lag the finger by the radius' share of the distance. It is measured in the camera's
    /// own space, where both terms carry `entityScale`, so the scale cancels and the drag tracks
    /// the finger on a phone and an iPad alike.
    ///
    /// Which way is north on screen is the camera's to say, not the drag's. The transition drives
    /// the tilt to overhead and leaves the *azimuth* exactly where the chunk was left — so a user
    /// who turned the chunk before pinching out arrives at a globe whose north is off to one side,
    /// and a drag read as though north were up walks the world somewhere they were not pointing.
    private func steerGlobe(dx: Float, dy: Float) {
        let radius = globeRadiusInView
        guard radius > 0, viewSize.height > 0 else { return }
        let surface = max(cameraController.distance - radius, 0.01)
        let worldPerPoint = 2 * surface * tan(Self.halfFieldOfView) / Float(viewSize.height)
        let metersPerPoint = Double(worldPerPoint / radius) * Turf.earthRadiusMeters

        // The ground follows the finger, so the coordinate under the camera goes the other way —
        // opposite in east, and opposite in south, which is northward.
        let ground = cameraController.groundDrag(deltaX: dx, deltaY: dy)
        store.steerGlobe(
            east: -Double(ground.x) * metersPerPoint,
            north: Double(ground.y) * metersPerPoint
        )
    }

    // MARK: - Zooming

    /// Sends a zoom delta to whichever of the three things is currently the one being zoomed.
    ///
    /// In order: the globe once it is showing, the *map* while the chunk still has ground to widen
    /// onto, and the camera only when there is no map to zoom. The chunk itself never changes size
    /// — pinching out shows more world across the same object on the table, which is what a map
    /// does, and is why panning goes on working the whole way out.
    private func zoom(by delta: Float) {
        if transition.isShowingGlobe {
            absorbIntoTransition(delta)
            return
        }
        guard store.canZoomGround else {
            guard globeStyle != nil, store.globe != nil, !chunkHasZoomRoom, delta < 0 else {
                cameraController.zoom(delta: delta)
                return
            }
            absorbIntoTransition(delta)
            return
        }

        // Positive delta is the camera's "closer", which for a map is less ground.
        store.zoomGround(by: exp2(-delta * Self.groundZoomOctaves))

        if delta < 0, !chunkHasZoomRoom, globeStyle != nil, store.globe != nil {
            absorbIntoTransition(delta)
        }
    }

    /// Whether a zoom-out still has somewhere to go before the world has to take over.
    ///
    /// Two different questions with one answer, because the handoff is one moment: a chunk that
    /// zooms its ground runs out when the map reaches the scale a flat cut stops suiting, and a
    /// fixed chunk — which has no map to widen — runs out when the orbit reaches its furthest.
    private var chunkHasZoomRoom: Bool {
        guard store.canZoomGround else {
            return cameraController.distance < cameraController.maxDistance
        }
        return store.groundScale < store.groundScaleLimits.upperBound * 0.999
    }

    // MARK: - The Globe Handoff

    private func absorbIntoTransition(_ delta: Float) {
        let absorption = transition.absorb(
            zoomDelta: delta,
            cameraDistance: cameraController.distance,
            cameraElevation: cameraController.elevation,
            chunkHasRoom: chunkHasZoomRoom
        )
        guard absorption.consumed else { return }
        // The relocation is decided *before* the camera is re-framed, and the order is the whole of
        // it: framing at zero progress re-docks the globe onto the chunk's current centre — see
        // `applyTransitionFraming` — and the dock is exactly what `beginRelocation` reads to decide
        // where to land. Framed first, that overwrites the steered dock and then measures the
        // landing against it: zero distance, early return, no relocation at all. What that looks
        // like is the *old* chunk dissolving back in over a globe spun to another continent, with
        // nothing logged. It is a narrower hazard now the return is committed at progress 1 rather
        // than scrubbed down to 0, but ordering it correctly costs nothing and it is exactly the
        // kind of thing that comes back.
        if absorption.committedReturn {
            beginRelocation()
        }
        applyTransitionFraming()
    }

    /// Moves the orbit camera to the framing the transition's progress asks for.
    private func applyTransitionFraming() {
        let limits = transition.elevationLimits(chunkRange: chunkElevationLimits)
        cameraController.minElevation = limits.lowerBound
        cameraController.maxElevation = limits.upperBound
        if let elevation = transition.cameraElevation() {
            cameraController.elevation = elevation
        }
        cameraController.elevation = min(max(cameraController.elevation, limits.lowerBound), limits.upperBound)
        cameraController.target = transition.cameraTarget(
            chunkCenterY: chunkCenterY * entityScale,
            globeRadius: globeRadiusInView
        )
        if let distance = transition.cameraDistance(globeDistance: globeDistanceInView) {
            cameraController.distance = distance
        }
        // The globe grows out of the chunk rather than the camera retreating from a sphere it was
        // already inside — see `GlobeTransition.globeScale`. It goes through the store because the
        // pivot is the dock, not the entity's own origin.
        store.setGlobeScale(transition.globeScale)

        // The dock is what makes the chunk and the globe agree about the origin, and moving it is a
        // rotation of the whole world — so it may only move while nothing is looking. Progress 0 is
        // the one moment the globe is fully gone.
        if transition.progress <= 0 {
            store.dockGlobe()
        }
    }

    /// Applies the cross-fade, and keeps a fully faded half out of the render entirely.
    private func applyTransitionVisibility() {
        if let entity = store.dioramaEntity {
            let opacity = transition.chunkOpacity
            entity.isEnabled = opacity > 0.001
            entity.components.set(OpacityComponent(opacity: opacity))
        }
        if let globe = store.globe {
            let opacity = transition.globeOpacity
            globe.isEnabled = opacity > 0.001
            globe.components.set(OpacityComponent(opacity: opacity))
        }
    }

    /// Rebuilds the chunk at whatever the globe was spun to.
    ///
    /// Fired as soon as the pinch starts coming back in rather than when it finishes, so the new
    /// ground is fetched during the dissolve instead of after it.
    ///
    /// The landing is the dock's own coordinate rather than whatever the camera happens to face,
    /// because steering *re-docks* — spinning the world puts the aimed-at ground at the sphere's
    /// top, which is where the chunk will be rebuilt. Asking the camera instead makes the landing
    /// depend on the tilt at the single frame progress leaves 1, and that tilt is mid-unwind by
    /// then: measured, half a degree short of overhead, which is 42 km of ground and enough to
    /// relocate a chunk nobody asked to move.
    private func beginRelocation() {
        guard let dock = store.globeDock else {
            logger.debug("Came back from the globe with nothing docked; keeping the chunk")
            return
        }
        let landing = dock.coordinate
        let current = Coordinate(store.configuration.center)
        // Straight back to where they started; the chunk in hand is already the right one. Logged
        // because it is indistinguishable on screen from a relocation that never fired at all.
        let travelled = Turf.distance(from: current, to: landing)
        guard travelled > store.configuration.radiusMeters / 4 else {
            logger.debug("Came back onto the same ground (\(travelled, format: .fixed(precision: 0)) m); keeping the chunk")
            return
        }
        // The globe carries the scene for the whole rebuild, which the pinch knows nothing about:
        // `relocate` nils the chunk entity from its first line to its last, so a crossfade run off
        // the finger's own clock hands back to nothing — the globe finishes fading half way through
        // the fetch, and the new chunk appears at full opacity with no dissolve at all.
        transition.beginHold()
        lastTransitionDate = nil
        applyTransitionFraming()
        applyTransitionVisibility()
        Task {
            await store.relocate(to: landing)
            store.applyContent(content)
            frameLoadedChunk()
            if case .failed = store.loadingState {
                // Nothing to hand back to. Staying on the globe keeps the failure legible — and the
                // overlay stops being suppressed, so the error surfaces.
                transition.abandonHold()
            } else {
                transition.endHold()
            }
            applyTransitionFraming()
            applyTransitionVisibility()
        }
    }

    /// Advances whichever leg of the handoff is playing.
    ///
    /// Its clock is separate from the route preview's because the two run independently; sharing one
    /// date would have whichever ticked first consume the other's elapsed time.
    ///
    /// **The clock is cleared by the step that ends the leg, not by a later tick that finds nothing
    /// animating.** There is no later tick: the timeline is paused the moment `isAnimating` goes
    /// false, so a date left behind here survives however long the scene sits settled and arrives as
    /// the *next* leg's first elapsed time. That is a handoff which plays properly the first time and
    /// snaps thereafter — and it reads as the pinch deciding, because a user who cycles is a user
    /// who pinches hard.
    private func advanceTransition(at date: Date) {
        guard transition.isAnimating else {
            lastTransitionDate = nil
            return
        }
        guard let last = lastTransitionDate else {
            lastTransitionDate = date
            legStart = date
            legSteps = 0
            return
        }
        lastTransitionDate = date
        legSteps += 1
        transition.advance(by: Float(date.timeIntervalSince(last)))
        if !transition.isAnimating {
            lastTransitionDate = nil
            // A leg that took one step is a leg that snapped, and on screen that is indistinguishable
            // from a handoff nobody asked to be gradual. Logged with its step count because the
            // difference between playing and jumping is not visible in a still.
            let seconds = legStart.map { date.timeIntervalSince($0) } ?? 0
            logger.debug("""
                Globe handoff settled at \(transition.progress, format: .fixed(precision: 0)) \
                after \(legSteps) steps over \(seconds, format: .fixed(precision: 2)) s
                """)
        }
        applyTransitionFraming()
        applyTransitionVisibility()
    }
}
#endif
