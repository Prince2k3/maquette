#if os(iOS) || os(macOS)
import CoreLocation
import Foundation
import Testing
import simd
@testable import Maquette

/// The shared platform-view model, now testable precisely because it left the view structs.
///
/// The logic here used to be private methods on two views that had drifted apart — the transition
/// clock reset existed on iOS and not on macOS — so these tests pin the behaviours that hid in
/// that drift.
@MainActor
@Suite("Orbit Diorama Model Tests")
struct OrbitDioramaModelTests {

    private static func makeModel() -> OrbitDioramaModel {
        OrbitDioramaModel(
            configuration: DioramaConfiguration(
                center: CLLocationCoordinate2D(latitude: 36.0, longitude: -112.0),
                radiusMeters: 5000
            ),
            content: nil
        )
    }

    @Test("With no map to zoom, a zoom delta reaches the camera")
    func zoomFallsThroughToCamera() {
        let model = Self.makeModel()
        // Nothing is loaded: no ground zoom, no globe. The camera is all that is left.
        let before = model.cameraController.distance
        model.zoom(by: -1)
        #expect(model.cameraController.distance > before)
    }

    @Test("A fixed chunk never reports zoom room, because it can never depart")
    func fixedChunkHasNoZoomRoom() {
        let model = Self.makeModel()
        // The handoff rides the ground zoom; with none, the transition is never consulted and the
        // camera keeps whatever range the caller gave it.
        #expect(!model.chunkHasZoomRoom)
        model.cameraController.distance = model.cameraController.maxDistance - 0.5
        #expect(!model.chunkHasZoomRoom)
    }

    @Test("A fixed chunk's zoom-out never starts a departure")
    func fixedChunkZoomNeverDeparts() {
        let model = Self.makeModel()
        model.globeStyle = GlobeTransitionStyle()
        model.transition.style = GlobeTransitionStyle()
        for _ in 0..<50 { model.zoom(by: -10) }
        #expect(!model.transition.isBusy)
        #expect(model.transition.progress == 0)
    }

    @Test("Interaction is locked exactly while a handoff leg is playing")
    func interactionLockFollowsTheLeg() {
        let model = Self.makeModel()
        #expect(!model.isInteractionLocked)
        model.transition.style = GlobeTransitionStyle()
        _ = model.transition.absorb(
            zoomDelta: -1,
            cameraDistance: model.cameraController.distance,
            cameraElevation: model.cameraController.elevation,
            chunkHasRoom: false
        )
        #expect(model.isInteractionLocked)
    }

    @Test("The transition clock is cleared by the step that ends the leg")
    func transitionClockClearsOnSettle() {
        let model = Self.makeModel()
        model.transition.style = GlobeTransitionStyle()
        _ = model.transition.absorb(
            zoomDelta: -1,
            cameraDistance: model.cameraController.distance,
            cameraElevation: model.cameraController.elevation,
            chunkHasRoom: false
        )
        #expect(model.transition.isAnimating)

        // Play the whole departure out at a steady 60 Hz.
        var date = Date(timeIntervalSinceReferenceDate: 0)
        model.advanceTransition(at: date)
        while model.transition.isAnimating {
            date = date.addingTimeInterval(1.0 / 60.0)
            model.advanceTransition(at: date)
        }

        // The regression this pins: a date left behind survives however long the scene sits
        // settled and arrives as the *next* leg's first elapsed time — a handoff that plays
        // properly once and snaps forever after. The clock must be nil the moment the leg ends,
        // not on some later tick, because the timeline pauses and there is no later tick.
        #expect(model.lastTransitionDate == nil)
        #expect(model.transition.progress == 1)
    }

    @Test("A locked model refuses drags outright")
    func lockedModelIgnoresDrags() {
        let model = Self.makeModel()
        model.transition.style = GlobeTransitionStyle()
        _ = model.transition.absorb(
            zoomDelta: -1,
            cameraDistance: model.cameraController.distance,
            cameraElevation: model.cameraController.elevation,
            chunkHasRoom: false
        )
        let azimuth = model.cameraController.azimuth
        let elevation = model.cameraController.elevation
        model.secondaryDrag(dx: 100, dy: 50)
        model.primaryDrag(dx: 100, dy: 50)
        #expect(model.cameraController.azimuth == azimuth)
        #expect(model.cameraController.elevation == elevation)
    }

    @Test("Disabled rotate leaves the camera alone but a pannable check still answers")
    func gestureSetGatesRotation() {
        let model = Self.makeModel()
        model.enabledGestures = [.zoom]
        let azimuth = model.cameraController.azimuth
        model.secondaryDrag(dx: 100, dy: 0)
        #expect(model.cameraController.azimuth == azimuth)
        #expect(!model.canPanTerrain)
    }

    @Test("The framing is view-size-invariant: the entity is never scaled by the window")
    func entityScaleIsPinnedAtOne() {
        let model = Self.makeModel()
        for size in [CGSize(width: 390, height: 844), CGSize(width: 400, height: 400),
                     CGSize(width: 1200, height: 800), CGSize(width: 2000, height: 600)] {
            model.viewSize = size
            #expect(model.entityScale == 1)
        }
        #if os(iOS)
        model.arPlacementActive = true
        #expect(model.entityScale == 1)
        #endif
    }

    @Test("A window resize does not move the camera's target")
    func resizeLeavesTheTargetAlone() {
        let model = Self.makeModel()
        // Stand in for a loaded chunk: the target the framing derived from its midpoint.
        model.chunkCenterY = -0.15
        model.cameraController.target.y = model.chunkCenterY * model.entityScale
        model.viewSize = CGSize(width: 1200, height: 800)
        model.updateEntityScale()
        // The regression this pins: the entity used to rescale with the view while the target kept
        // the old scale's midpoint, so every resize drifted the chunk vertically out of frame.
        #expect(model.cameraController.target.y == model.chunkCenterY)
    }

    @Test("The orbit limit leaves a fixed chunk's zoom range alone")
    func orbitLimitSparesFixedChunks() {
        let model = Self.makeModel()
        model.globeStyle = GlobeTransitionStyle()
        let range = model.cameraController.maxDistance
        // No ground zoom: the chunk can never depart, so narrowing the orbit toward a handoff
        // that will not happen would only take zoom away from the camera.
        model.applyOrbitLimit()
        #expect(model.cameraController.maxDistance == range)
    }

    @Test("The overlay reports loading only when the globe is not carrying the scene")
    func overlayStateSuppression() {
        let model = Self.makeModel()
        // Nothing loaded and no globe showing: the store's own state comes straight through.
        if case .idle = model.overlayState {
        } else {
            Issue.record("Expected the store's idle state to pass through, got \(model.overlayState)")
        }
    }
}

@Suite("Orbit camera pan mapping")
struct OrbitCameraPanMappingTests {

    @Test("Dragging moves the ground with the finger")
    @MainActor
    func dragMovesGroundWithFinger() {
        let camera = CameraController(elevation: 0.5, distance: 1.0)
        camera.azimuth = 0

        // At azimuth 0 the camera looks down -Z, so screen right is +X.
        let right = camera.terrainPanDelta(
            dragDeltaX: 10, dragDeltaY: 0, viewHeight: 800, entityScale: 1
        )
        // Terrain is sampled at position + offset, so moving ground right lowers the offset.
        #expect(right.x < 0, "Dragging right should slide the ground right")
        #expect(abs(right.y) < 1e-6)

        let down = camera.terrainPanDelta(
            dragDeltaX: 0, dragDeltaY: 10, viewHeight: 800, entityScale: 1
        )
        #expect(down.y < 0, "Dragging down should slide the ground toward the viewer")
    }

    @Test("Pan direction follows the camera around the chunk")
    @MainActor
    func panFollowsCameraRotation() {
        let camera = CameraController(elevation: 0.5, distance: 1.0)
        camera.azimuth = .pi / 2

        let delta = camera.terrainPanDelta(
            dragDeltaX: 10, dragDeltaY: 0, viewHeight: 800, entityScale: 1
        )
        // A quarter turn swaps which world axis "screen right" corresponds to.
        #expect(abs(delta.x) < 1e-6)
        #expect(delta.y > 0)
    }

    @Test("Zooming in makes panning finer")
    @MainActor
    func panScalesWithZoom() {
        let near = CameraController(elevation: 0.5, distance: 0.5)
        let far = CameraController(elevation: 0.5, distance: 2.0)

        let nearDelta = near.terrainPanDelta(dragDeltaX: 10, dragDeltaY: 0, viewHeight: 800, entityScale: 1)
        let farDelta = far.terrainPanDelta(dragDeltaX: 10, dragDeltaY: 0, viewHeight: 800, entityScale: 1)

        #expect(abs(nearDelta.x) < abs(farDelta.x),
                "The same drag should cover less ground when zoomed in")
    }
}

/// Which way a drag points once the camera has been turned.
///
/// The transition drives the tilt to overhead and leaves the azimuth where the chunk was left, so a
/// non-zero azimuth on the globe is the ordinary case rather than the exotic one: anyone who turned
/// the chunk before pinching out arrives with north somewhere other than up the screen.
@Suite("Screen axes on the ground")
@MainActor
struct GroundDragTests {
    private func camera(azimuth: Float) -> CameraController {
        let controller = CameraController()
        controller.azimuth = azimuth
        return controller
    }

    @Test("Facing north, right is east and down is south")
    func theDefaultFraming() {
        let ground = camera(azimuth: 0).groundDrag(deltaX: 1, deltaY: 0)
        #expect(abs(ground.x - 1) < 1e-6)
        #expect(abs(ground.y) < 1e-6)

        let down = camera(azimuth: 0).groundDrag(deltaX: 0, deltaY: 1)
        #expect(abs(down.x) < 1e-6)
        #expect(abs(down.y - 1) < 1e-6)
    }

    /// A quarter turn puts the diorama's north up the *side* of the screen, so a horizontal drag is
    /// entirely a change of latitude. Read as though north were still up, the same drag would have
    /// changed longitude — a right angle's worth of wrong, and on a globe it looks like nothing at
    /// all until the chunk comes back somewhere else.
    @Test("A quarter turn swaps which axis a drag moves")
    func aQuarterTurn() {
        let ground = camera(azimuth: .pi / 2).groundDrag(deltaX: 1, deltaY: 0)
        #expect(abs(ground.x) < 1e-6)
        #expect(abs(ground.y + 1) < 1e-6)   // −Z: the ground moves north
    }

    /// Whatever the azimuth, a drag moves the ground by its own length — the camera turns the
    /// direction and must never scale it.
    @Test("Turning the camera never changes how far a drag reaches")
    func lengthIsPreserved() {
        for step in 0...12 {
            let ground = camera(azimuth: Float(step) * .pi / 6).groundDrag(deltaX: 3, deltaY: -4)
            #expect(abs(simd_length(ground) - 5) < 1e-5)
        }
    }
}
#endif
