#if os(iOS) || os(macOS)
import CoreLocation
import Foundation
import Testing
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

    @Test("A fixed chunk has zoom room until the orbit reaches its furthest")
    func chunkZoomRoomTracksTheOrbit() {
        let model = Self.makeModel()
        model.cameraController.distance = model.cameraController.maxDistance - 0.5
        #expect(model.chunkHasZoomRoom)
        model.cameraController.distance = model.cameraController.maxDistance
        #expect(!model.chunkHasZoomRoom)
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
#endif
