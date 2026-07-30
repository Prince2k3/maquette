import Foundation
import Testing
import simd
@testable import Maquette

/// What a drag on the globe has to mean.
///
/// Steering is the one gesture whose mistakes cannot be seen: the chunk sliding the wrong way is
/// obvious on screen, whereas a globe spun to the wrong place is still a globe, spinning. Both of
/// the errors pinned here looked completely plausible while they were live, and both end up
/// somewhere the user did not point — which the return leg then cuts a chunk out of.
@Suite("Globe steering")
struct GlobeSteeringTests {
    /// A drag that never left the horizontal must not change latitude.
    ///
    /// It used to, because the walk was a single great circle on the resulting bearing and a great
    /// circle leaving on a bearing of 90° curves back towards the equator. One step hides it; a
    /// swipe is twenty of them, and the drift compounds.
    @Test("Dragging sideways stays on the parallel")
    func steeringEastKeepsItsLatitude() {
        var here = Coordinate(latitude: 45, longitude: 0)
        var byGreatCircle = here
        for _ in 0..<20 {
            here = DioramaStore.steered(here, east: 280_000, north: 0)
            byGreatCircle = Turf.destination(from: byGreatCircle, meters: 280_000, bearing: 90)
        }

        #expect(abs(here.latitude - 45) < 1e-9)
        // What it was doing instead: 121 km south of a drag that only went sideways.
        #expect(45 - byGreatCircle.latitude > 1.0)
    }

    /// And it must cover the ground it was asked for while doing it. A parallel is shorter than the
    /// equator, so the same metres are more longitude the further north they are walked — the test
    /// is on the distance, not on the longitude.
    @Test("Sideways still moves the distance it was given")
    func steeringEastMovesTheGroundAsked() {
        for latitude in [0.0, 45.0, 70.0] {
            let origin = Coordinate(latitude: latitude, longitude: 10)
            let moved = DioramaStore.steered(origin, east: 200_000, north: 0)
            #expect(abs(Turf.distance(from: origin, to: moved) - 200_000) < 200)
            #expect(moved.longitude > origin.longitude)
        }
    }

    @Test("Dragging up and down walks the meridian")
    func steeringNorthKeepsItsLongitude() {
        let origin = Coordinate(latitude: 36.0544, longitude: -112.1401)
        let north = DioramaStore.steered(origin, east: 0, north: 150_000)
        #expect(abs(north.longitude - origin.longitude) < 1e-9)
        #expect(abs(Turf.distance(from: origin, to: north) - 150_000) < 1)

        let south = DioramaStore.steered(origin, east: 0, north: -150_000)
        #expect(south.latitude < origin.latitude)
        #expect(abs(south.longitude - origin.longitude) < 1e-9)
    }

    /// The walk stops where the imagery does. Left to run, a great-circle step over the pole comes
    /// down the far side with the longitude flipped by 180° — the whole world spinning half a turn
    /// mid-drag, and then travelling backwards under a finger that never changed direction.
    @Test("Steering north stops at the edge of the map rather than crossing the pole")
    func steeringStopsAtMercatorsLimit() {
        var here = Coordinate(latitude: 80, longitude: 10)
        for _ in 0..<30 {
            here = DioramaStore.steered(here, east: 0, north: 280_000)
        }
        #expect(abs(here.latitude - GlobeGeometry.mercatorLimitDegrees) < 1e-9)
        #expect(abs(here.longitude - 10) < 1e-9)

        var south = Coordinate(latitude: -80, longitude: 10)
        for _ in 0..<30 {
            south = DioramaStore.steered(south, east: 0, north: -280_000)
        }
        #expect(abs(south.latitude + GlobeGeometry.mercatorLimitDegrees) < 1e-9)
        #expect(abs(south.longitude - 10) < 1e-9)

        // What the unclamped walk does instead, one step from the pole.
        let crossed = Turf.destination(from: Coordinate(latitude: 89.5, longitude: 10), meters: 280_000, bearing: 0)
        #expect(abs(Turf.normalizedLongitude(crossed.longitude) - 10) > 179)
    }

    /// The antimeridian is not an edge. Rows clamp because Mercator ends; columns wrap because the
    /// world does.
    @Test("Steering east across the antimeridian wraps")
    func steeringWrapsInLongitude() {
        let origin = Coordinate(latitude: 0, longitude: 179)
        let moved = DioramaStore.steered(origin, east: 400_000, north: 0)
        #expect(moved.longitude < 0)
        #expect(abs(Turf.distance(from: origin, to: moved) - 400_000) < 200)
    }

    /// Zero movement leaves the dock exactly alone, so a touch that lands without moving cannot
    /// re-dock the world by a rounding error.
    @Test("A drag of nothing moves nothing")
    func steeringNowhereGoesNowhere() {
        let origin = Coordinate(latitude: 36.0544, longitude: -112.1401)
        let moved = DioramaStore.steered(origin, east: 0, north: 0)
        #expect(moved.latitude == origin.latitude)
        #expect(moved.longitude == origin.longitude)
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
