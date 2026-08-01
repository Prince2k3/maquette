#if os(iOS) || os(macOS)
import Foundation
import RealityKit
import SwiftUI

/// Shared state and scene logic for the two orbit-camera platforms.
///
/// iOS and macOS present the same scene the same way — an orbit camera around the chunk, the
/// ground-zoom ladder, and the globe handoff — and differ only in the input that drives it: raw
/// multitouch on iOS, pointer-and-modifier drags on macOS. Everything below the gesture layer
/// lives here once, so a fix cannot land on one platform and quietly miss the other; the platform
/// views translate their input vocabulary into the intent methods (``panTerrain(dx:dy:at:)``,
/// ``steerOrOrbit(dx:dy:)``, ``zoomInput(_:)``) and own nothing else.
@MainActor
@Observable
final class OrbitDioramaModel {
    let store: DioramaStore
    let cameraController = CameraController()
    /// The handoff's shared mechanics; the model supplies the orbit-camera framing response.
    let handoff = GlobeHandoffConductor()
    private(set) var content: DioramaContentGroup?

    /// The transition, read and written through the conductor that owns it.
    var transition: GlobeTransition {
        get { handoff.transition }
        set { handoff.transition = newValue }
    }

    /// The transition's animation clock, owned by the conductor. Exposed for the tests that pin
    /// the clock-clearing regression.
    var lastTransitionDate: Date? { handoff.lastTransitionDate }

    var viewSize = CGSize(width: 400, height: 400)

    /// Environment mirrors, pushed in by the shared view — the model has no view hierarchy to read
    /// them from, and the intent routing below needs them.
    var enabledGestures: Set<DioramaGestureType> = [.rotate, .zoom, .pan]
    var displayScale: CGFloat = 1
    var routePreviewController: RoutePreviewController?
    var globeStyle: GlobeTransitionStyle?

    /// The camera-position binding handed to `DioramaView`, and the value last applied through it.
    ///
    /// The guard against feedback: gestures write the binding, the binding's `onChange` calls
    /// ``applyCameraPosition(_:)``, and without remembering what was last written the write-back
    /// would re-apply itself. Single-direction sync — apply on change in, publish on gesture out.
    var positionBinding: Binding<DioramaCameraPosition>?
    private var lastAppliedPosition: DioramaCameraPosition?

    /// The selection binding handed to `DioramaView`, written on marker taps.
    var selectionBinding: Binding<DioramaAnnotation.ID?>?

    /// Observation hooks from the environment.
    var cameraChangeAction: DioramaCameraChangeAction?
    var loadingChangeAction: DioramaLoadingChangeAction?

    var lastAnimationDate: Date?
    var chunkCenterY: Float = 0
    /// The orbit's own tilt range, captured before the transition starts widening it.
    var chunkElevationLimits: ClosedRange<Float> = 0...0

    init(configuration: DioramaConfiguration, content: DioramaContentGroup?) {
        self.store = DioramaStore(configuration: configuration)
        self.content = content
    }

    // MARK: - Lifecycle

    /// The initial load: camera request, effect, terrain, content, framing.
    func initialLoad(effect: DioramaEffect) async {
        applyCameraPosition(positionBinding?.wrappedValue)
        chunkElevationLimits = cameraController.minElevation...cameraController.maxElevation
        store.setEffect(effect)
        await store.load()
        store.applyContent(content)
        frameLoadedChunk()
    }

    /// Adopts a changed region/style key; see ``DioramaLiveInputs/applyReloadKey(_:store:content:afterLoad:)``.
    func applyReloadKey(_ key: DioramaViewInputs.ReloadKey) {
        DioramaLiveInputs.applyReloadKey(key, store: store, content: content) { [weak self] in
            self?.frameLoadedChunk()
        }
    }

    /// Re-applies changed content against the substrate already in hand.
    func setContent(_ newContent: DioramaContentGroup) {
        content = newContent
        store.applyContent(newContent)
        applySelection(selectionBinding?.wrappedValue)
    }

    // MARK: - Camera binding

    /// Applies an incoming camera request, once per distinct value.
    func applyCameraPosition(_ position: DioramaCameraPosition?) {
        guard let position, position != lastAppliedPosition else { return }
        lastAppliedPosition = position
        switch position.request {
        case .automatic:
            frameLoadedChunk()
        case .camera(let camera):
            cameraController.azimuth = Float(camera.azimuth.radians)
            cameraController.elevation = min(
                max(Float(camera.elevation.radians), cameraController.minElevation),
                cameraController.maxElevation
            )
            cameraController.distance = min(
                max(camera.distance, cameraController.minDistance),
                cameraController.maxDistance
            )
        }
    }

    /// Publishes the camera a gesture just moved: to the binding, and to the observation hook.
    ///
    /// Called from gesture intents only — programmatic moves (the transition's framing, a route
    /// follow) are not the user positioning the camera, and `positionedByUser` should mean what
    /// it says.
    func publishCameraPosition() {
        let camera = DioramaCamera(
            azimuth: .radians(Double(cameraController.azimuth)),
            elevation: .radians(Double(cameraController.elevation)),
            distance: cameraController.distance
        )
        cameraChangeAction?.action(camera)
        guard let positionBinding else { return }
        let position = DioramaCameraPosition.userPositioned(camera)
        // Remembered as applied before writing, so the binding's own onChange does not re-apply it.
        lastAppliedPosition = position
        positionBinding.wrappedValue = position
    }

    // MARK: - Selection

    /// A tap landed on an entity; walk up for a marker and toggle the selection.
    func handleTap(on entity: Entity) {
        DioramaLiveInputs.handleTap(on: entity, selection: selectionBinding, store: store)
    }

    /// Reflects the selected identity onto the marker entities.
    func applySelection(_ id: DioramaAnnotation.ID?) {
        DioramaLiveInputs.applySelection(id, store: store)
    }

    /// The overlay's retry: tear down and load again.
    func reload() {
        store.reset()
        Task {
            await store.load()
            store.applyContent(content)
            frameLoadedChunk()
        }
    }

    /// Adopts a globe style from the environment and fetches the world it describes.
    func adoptGlobeStyle(_ style: GlobeTransitionStyle) async {
        globeStyle = style
        transition.style = style
        applyOrbitLimit()
        await store.loadGlobe(style: style)
    }

    /// Points the orbit camera at the chunk's vertical midpoint.
    ///
    /// The chunk hangs below Y = 0 by its base depth, so orbiting the origin would frame it high.
    func frameLoadedChunk() {
        guard let entity = store.dioramaEntity as? DioramaEntity else { return }
        chunkCenterY = entity.verticalCenter
        // A chunk arriving mid-handoff must not pull the camera back to it: the transition owns the
        // framing until it is finished, and a relocated chunk finishes loading in the middle of one.
        guard !transition.isShowingGlobe else { return }
        // This is also the transition's framing at progress 0, and the two disagreeing is a jump
        // on the first step.
        cameraController.target.y = chunkCenterY * entityScale
    }

    /// Pulls the orbit's furthest distance in to the chunk, so zooming out reaches the world.
    ///
    /// Only when a globe is on offer *and* the chunk can actually depart — the handoff rides the
    /// ground zoom, so a fixed diorama never leaves and narrowing its range would take zoom away
    /// from a camera that has nowhere else to go.
    func applyOrbitLimit() {
        guard globeStyle != nil, store.canZoomGround else { return }
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
    var overlayState: DioramaLoadingState {
        if transition.isShowingGlobe, case .loading = store.loadingState { return .loaded }
        return store.loadingState
    }

    /// Whether the diorama is currently parented to a real-world plane anchor (iOS AR placement).
    var arPlacementActive = false

    /// Scale applied to the diorama entity. Always 1: perspective projection owns window size.
    ///
    /// This used to grow the entity with the view (`min(w, h) / 400`), which is half a fix for a
    /// problem the projection already solves whole. A camera at a fixed distance with a fixed
    /// *vertical* field of view shows the chunk at the same fraction of the view's height whatever
    /// the window's size — scaling the object on top of that is what made a large window overflow
    /// the frustum, since nothing scaled the camera's distance to match. Scaling both together is a
    /// similarity transform, pixel-identical to scaling neither, so the scale is pinned at 1 and
    /// every distance in the model lives in one currency: diorama meters.
    ///
    /// The property survives as the seam the scale would go through if it were ever needed again,
    /// and because AR placement is the one consumer with an opinion: `physicalSize` is real meters
    /// there, and 1 is the value that lets it mean itself.
    var entityScale: Float { 1 }

    func updateEntityScale() {
        store.dioramaEntity?.scale = SIMD3<Float>(repeating: entityScale)
        // The globe takes the same scale about the same origin, or the dock stops meaning anything:
        // it is defined in diorama meters and the chunk it has to line up with is scaled.
        store.globe?.scale = SIMD3<Float>(repeating: entityScale)
        applyOrbitLimit()
        // A resize while settled on the globe changes the view's aspect, and with it the distance
        // that fits the whole world in frame — nothing else re-frames there, because the timeline
        // is paused and no leg is running.
        if transition.isShowingGlobe, !transition.isBusy {
            applyTransitionFraming()
        }
    }

    // MARK: - Animation

    /// Whether the shared timeline needs to tick at all.
    var needsAnimation: Bool {
        routePreviewController?.playbackState == .playing
            || cameraController.routeFollowPhase == .exiting
            || transition.isAnimating
    }

    func advanceAnimation(at date: Date) {
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

    /// Advances whichever leg of the handoff is playing. The clock discipline lives in the
    /// conductor; the model contributes its framing response.
    func advanceTransition(at date: Date) {
        handoff.advance(at: date) {
            applyTransitionFraming()
            applyTransitionVisibility()
        }
    }

    // MARK: - Gesture intents

    /// Whether the handoff owns the input right now.
    ///
    /// While a leg plays it owns the camera, the crossfade and the dock alike. A drag admitted here
    /// would fight all three: steering during the wait spins the world away from the ground already
    /// being fetched for it, and a rotate during either leg pulls against a tilt the transition is
    /// driving to a specific angle.
    var isInteractionLocked: Bool { transition.isBusy }

    /// Whether a single touch or plain drag should slide the terrain rather than orbit.
    var canPanTerrain: Bool {
        guard enabledGestures.contains(.pan) else { return false }
        let root = store.dioramaEntity as? DioramaEntity
        return root?.terrain?.canPan == true || root?.tiles3D?.canPan == true
    }

    /// Routes a primary drag: the globe steers, a pannable chunk pans, and a fixed diorama orbits.
    ///
    /// A single input slides the terrain, matching how a map behaves. When the chunk cannot pan —
    /// either the caller disabled it or the configuration set no pan range — it orbits instead, so
    /// a fixed diorama still responds the way it always has.
    func primaryDrag(dx: Float, dy: Float, at time: TimeInterval? = nil) {
        guard !isInteractionLocked else { return }
        // The globe has no ground to slide, so the drag spins it.
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
                at: time
            )
        } else if enabledGestures.contains(.rotate) {
            cameraController.rotate(deltaX: dx, deltaY: dy)
            publishCameraPosition()
        }
    }

    /// Routes a secondary drag: the globe steers, a chunk orbits.
    ///
    /// This is iOS's two-finger drag and macOS's option-drag — the input whose meaning is "turn",
    /// where the primary drag's is "move".
    func secondaryDrag(dx: Float, dy: Float) {
        guard !isInteractionLocked else { return }
        if transition.isShowingGlobe {
            steerGlobe(dx: dx, dy: dy)
            return
        }
        if enabledGestures.contains(.rotate) {
            cameraController.rotate(deltaX: dx, deltaY: dy)
            publishCameraPosition()
        }
    }

    /// Routes a zoom delta, honouring the caller's gesture set.
    func zoomInput(_ delta: Float) {
        guard !isInteractionLocked else { return }
        guard enabledGestures.contains(.zoom), delta != 0 else {
            if transition.isShowingGlobe { applyTransitionFraming() }
            return
        }
        zoom(by: delta)
    }

    // MARK: - Globe framing

    /// The globe's radius in the camera's space rather than the diorama's.
    var globeRadiusInView: Float {
        (store.globe?.radius ?? globeStyle?.radius ?? 0) * entityScale
    }

    /// Where the camera has to stand for the whole world to fit inside the frame.
    ///
    /// Framed against the *narrower* of the view's two half-angles, which for a tall view is the
    /// horizontal one and is a good deal tighter than the 60° the camera is configured with: at
    /// 402 × 674 points that is 19°, not 30°. Framing against the wider axis instead is how a globe
    /// ends up correctly distanced and still running off both sides of the screen.
    ///
    /// The camera's angle is the vertical one — stated on the camera itself, which
    /// ``DioramaSceneRig/makeOrbitCamera()`` configures with `fieldOfViewOrientation = .vertical`
    /// so this arithmetic and `terrainPanDelta` read the projection they actually get.
    var globeDistanceInView: Float {
        let vertical = DioramaSceneRig.halfFieldOfView
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
    /// would lag the finger by the radius' share of the distance. Distance and radius are both in
    /// diorama meters — the one currency the model has — so the drag tracks the finger whatever
    /// the view's size.
    ///
    /// Which way is north on screen is the camera's to say, not the drag's. The transition drives
    /// the tilt to overhead and leaves the *azimuth* exactly where the chunk was left — so a user
    /// who turned the chunk before pinching out arrives at a globe whose north is off to one side,
    /// and a drag read as though north were up walks the world somewhere they were not pointing.
    func steerGlobe(dx: Float, dy: Float) {
        let radius = globeRadiusInView
        guard radius > 0, viewSize.height > 0 else { return }
        let surface = max(cameraController.distance - radius, 0.01)
        let worldPerPoint = 2 * surface * tan(DioramaSceneRig.halfFieldOfView) / Float(viewSize.height)
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
    /// — zooming out shows more world across the same object on the table, which is what a map
    /// does, and is why panning goes on working the whole way out.
    ///
    /// **The globe handoff rides the map, never the camera.** A fixed diorama — no `panRange`, or
    /// the photorealistic pipeline, which has no height field to re-read — has no ground zoom, so
    /// its zoom is a plain camera dolly and it never departs for the globe however far out it goes.
    /// The handoff is a continuation of the map widening; departing from a chunk that cannot widen
    /// would hand back a globe whose return had no ladder to descend.
    func zoom(by delta: Float) {
        if transition.isShowingGlobe {
            absorbIntoTransition(delta)
            return
        }
        guard store.canZoomGround else {
            cameraController.zoom(delta: delta)
            publishCameraPosition()
            return
        }

        // Positive delta is the camera's "closer", which for a map is less ground.
        store.zoomGround(by: exp2(-delta * DioramaSceneRig.groundZoomOctaves))

        if delta < 0, !chunkHasZoomRoom, globeStyle != nil, store.globe != nil {
            absorbIntoTransition(delta)
        }
    }

    /// Whether a zoom-out still has somewhere to go before the world has to take over.
    ///
    /// Only a chunk with a ground zoom can run out of room: the map reaches the scale a flat cut
    /// stops suiting. A fixed chunk answers false, and nothing reads the answer there — its zoom
    /// path never consults the transition at all.
    var chunkHasZoomRoom: Bool {
        guard store.canZoomGround else { return false }
        return store.groundScale < store.groundScaleLimits.upperBound * 0.999
    }

    // MARK: - The Globe Handoff

    func absorbIntoTransition(_ delta: Float) {
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
    func applyTransitionFraming() {
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
    func applyTransitionVisibility() {
        handoff.applyVisibility(store: store)
    }

    /// Rebuilds the chunk at whatever the globe was spun to. The hold-and-rebuild mechanics live
    /// in the conductor; the model contributes the camera re-framing.
    func beginRelocation() {
        handoff.relocate(store: store, content: content) { [weak self] in
            self?.frameLoadedChunk()
        } applyFrames: { [weak self] in
            self?.applyTransitionFraming()
            self?.applyTransitionVisibility()
        }
    }
}
#endif
