import CoreLocation
import Foundation
import Testing
import simd
@testable import Maquette

@Suite("Ellipsoid Projection Tests")
struct EllipsoidProjectionTests {
    private static let center = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.4050)

    private func makeProjection(
        radiusMeters: Double = 700,
        physicalDiameter: Float = 0.8,
        datumElevation: Double = 0
    ) -> EllipsoidProjection {
        EllipsoidProjection(
            center: Self.center,
            radiusMeters: radiusMeters,
            physicalDiameter: physicalDiameter,
            datumElevation: datumElevation
        )
    }

    @Test("The diorama's centre is the origin")
    func centerIsTheOrigin() {
        let point = makeProjection().point(for: Coordinate(Self.center))
        #expect(abs(point.x) < 1e-4)
        #expect(abs(point.y) < 1e-4)
    }

    @Test("East is +X and north is -Z")
    func axisConvention() {
        let projection = makeProjection()
        let east = projection.point(
            for: Coordinate(latitude: Self.center.latitude, longitude: Self.center.longitude + 0.001)
        )
        let north = projection.point(
            for: Coordinate(latitude: Self.center.latitude + 0.001, longitude: Self.center.longitude)
        )
        #expect(east.x > 0)
        #expect(abs(east.y) < 1e-3)
        #expect(north.y < 0)
        #expect(abs(north.x) < 1e-3)
    }

    @Test("Distance scales by the entity scale the tiles are drawn at")
    func scaleMatchesTheGeometry() {
        // The scale `Tiles3DEntity` applies: half the physical diameter per radius of real ground.
        let projection = makeProjection(radiusMeters: 700, physicalDiameter: 0.8)
        #expect(abs(projection.geographicScale - 0.8 / 1400) < 1e-9)

        // A tenth of a degree of latitude is about 11.1 km; checking the ratio rather than the
        // absolute keeps this a statement about the scaling rather than about WGS84's arithmetic.
        let near = projection.point(
            for: Coordinate(latitude: Self.center.latitude + 0.001, longitude: Self.center.longitude)
        )
        let far = projection.point(
            for: Coordinate(latitude: Self.center.latitude + 0.002, longitude: Self.center.longitude)
        )
        #expect(abs(far.y / near.y - 2) < 1e-3)
    }

    @Test("A metre north is a metre, through the ellipsoid rather than a sphere")
    func metreScale() {
        let projection = makeProjection(radiusMeters: 1, physicalDiameter: 2)
        // A 1 m radius against a 2 m diameter is a scale of exactly 1, so the point is real metres.
        #expect(abs(projection.geographicScale - 1) < 1e-6)

        // 0.001° of latitude near 37.8°N is 111.0–111.1 m on WGS84. A 6 371 km sphere gives
        // 111.2 m, which is the error this projection exists to remove.
        let north = projection.point(
            for: Coordinate(latitude: Self.center.latitude + 0.001, longitude: Self.center.longitude)
        )
        #expect(-north.y > 110.9)
        #expect(-north.y < 111.2)
    }

    @Test("Altitude is measured from the datum the model was dropped to")
    func datumIsTheOrigin() {
        let projection = makeProjection(radiusMeters: 700, physicalDiameter: 0.8, datumElevation: 12)
        #expect(abs(projection.y(forElevation: 12)) < 1e-9)
        #expect(abs(projection.y(forElevation: 112) - 100 * projection.geographicScale) < 1e-6)
    }

    @Test("Without a ground sampler a coordinate rests on the datum")
    func groundDefaultsToTheDatum() throws {
        let projection = makeProjection()
        // Deliberately a floor rather than a guess: photogrammetry is triangle soup, so until
        // something can raycast it, a pin lands at the tray's top rather than vanishing.
        #expect(try #require(projection.position(for: Coordinate(Self.center))).y == 0)
    }

    @Test("A ground sampler is used when one is supplied")
    func groundSamplerWins() throws {
        var projection = makeProjection()
        projection.groundSampler = { _, _ in 0.25 }
        #expect(try #require(projection.position(for: Coordinate(Self.center))).y == 0.25)
    }

    @Test("Panning moves a coordinate with the ground it sits on")
    func panningCarriesCoordinates() {
        var projection = makeProjection()
        let before = projection.point(for: Coordinate(Self.center))
        let offset = SIMD2<Float>(0.05, -0.03)
        projection.panOffset = offset
        let after = projection.point(for: Coordinate(Self.center))

        #expect(abs((after.x - before.x) - -offset.x) < 1e-6)
        #expect(abs((after.y - before.y) - -offset.y) < 1e-6)
    }

    @Test("A zero radius does not produce an infinite scale")
    func degenerateRadius() {
        #expect(makeProjection(radiusMeters: 0).geographicScale == 1)
    }
}
