import Foundation
import Testing
import simd
@testable import Maquette

/// What the dock has to get right for a chunk and a globe to be the same place.
///
/// Every one of these fails invisibly. A globe docked with the right up vector and the wrong spin
/// is still a globe with the correct country facing the camera — the compass is simply wrong, and
/// nothing on a sphere of satellite imagery says which way is north. A dock that puts the
/// coordinate near the origin rather than on it reads as a slightly off-centre planet.
@Suite("Globe dock")
struct GlobeDockTests {
    private let radius: Float = 2

    private let samples = [
        Coordinate(latitude: 0, longitude: 0),
        Coordinate(latitude: 37.7749, longitude: -122.4194),
        Coordinate(latitude: -33.8688, longitude: 151.2093),
        Coordinate(latitude: 46.8523, longitude: -121.7603),
        Coordinate(latitude: 64.1466, longitude: -21.9426),
        Coordinate(latitude: 0, longitude: 179.9),
    ]

    // MARK: - Placement

    @Test("The docked coordinate lands on the diorama origin")
    func dockedCoordinateIsTheOrigin() {
        for sample in samples {
            let dock = GlobeDock(coordinate: sample, radius: radius)
            let point = dock.dioramaPoint(for: sample)
            #expect(simd_length(point) < 1e-4, "\(sample.latitude), \(sample.longitude) → \(point)")
        }
    }

    @Test("The globe's centre is directly below the table")
    func centreHangsBelowTheOrigin() {
        let dock = GlobeDock(coordinate: samples[1], radius: radius)
        #expect(dock.center == SIMD3<Float>(0, -radius, 0))
        // And the origin is exactly a radius from it, which is the same statement as the surface
        // touching the table.
        #expect(abs(simd_length(dock.center) - radius) < 1e-5)
    }

    // MARK: - Orientation

    /// The whole reason the rotation is built from a full basis rather than an axis-angle pair.
    /// Getting the up vector right leaves the globe free to spin about it, which puts north
    /// somewhere arbitrary under a chunk that is drawn north-up.
    @Test("North goes to −Z and east to +X")
    func compassMatchesTheChunk() {
        for sample in samples {
            let dock = GlobeDock(coordinate: sample, radius: radius)
            // A tenth of a degree is small enough that the sphere is locally flat and large enough
            // to survive Float.
            let north = Coordinate(latitude: sample.latitude + 0.1, longitude: sample.longitude)
            let east = Coordinate(latitude: sample.latitude, longitude: sample.longitude + 0.1)

            let toNorth = simd_normalize(dock.dioramaPoint(for: north))
            let toEast = simd_normalize(dock.dioramaPoint(for: east))

            #expect(toNorth.z < -0.99, "north at \(sample.latitude) → \(toNorth)")
            #expect(toEast.x > 0.99, "east at \(sample.latitude) → \(toEast)")
        }
    }

    @Test("The antipode is directly below the globe's centre")
    func antipodeIsStraightDown() {
        let dock = GlobeDock(coordinate: samples[1], radius: radius)
        let antipode = Coordinate(
            latitude: -samples[1].latitude,
            longitude: samples[1].longitude - 180
        )
        let point = dock.dioramaPoint(for: antipode)
        #expect(abs(point.x) < 1e-3)
        #expect(abs(point.z) < 1e-3)
        #expect(abs(point.y - -2 * radius) < 1e-3)
    }

    /// East is taken from the longitude tangent precisely so the poles stay well defined, where the
    /// usual north-tangent formula collapses.
    @Test("The rotation stays a rotation at the poles")
    func polesProduceAValidRotation() {
        for latitude in [90.0, -90.0, 89.9999] {
            let dock = GlobeDock(coordinate: Coordinate(latitude: latitude, longitude: 0), radius: radius)
            let matrix = simd_float3x3(dock.rotation)
            for column in [matrix.columns.0, matrix.columns.1, matrix.columns.2] {
                #expect(abs(simd_length(column) - 1) < 1e-4, "\(latitude): \(column)")
            }
            #expect(abs(simd_determinant(matrix) - 1) < 1e-3, "\(latitude)")
        }
    }

    // MARK: - Reading a coordinate back

    /// How zooming in picks its new centre: whatever the globe is presenting towards the camera.
    @Test("A camera above the origin faces the docked coordinate")
    func cameraOverTheOriginReadsBackTheDock() {
        for sample in samples {
            let dock = GlobeDock(coordinate: sample, radius: radius)
            let facing = try! #require(dock.coordinate(facing: SIMD3<Float>(0, 0.5, 0)))
            #expect(abs(facing.latitude - sample.latitude) < 1e-3)
            // Longitude is meaningless at the pole, and the last sample sits on the antimeridian
            // where ±180 are the same place.
            if abs(sample.latitude) < 89.9 {
                let delta = abs(facing.longitude - sample.longitude)
                #expect(min(delta, 360 - delta) < 1e-3)
            }
        }
    }

    /// The round trip the handoff actually performs: spin to a coordinate, put the camera over it,
    /// and read it back.
    @Test("Any coordinate can be spun into view and read back")
    func spinningAndReadingBackRoundTrips() {
        let dock = GlobeDock(coordinate: samples[1], radius: radius)
        for target in samples {
            let onSphere = dock.dioramaPoint(for: target)
            // The camera sits outside the surface along the same ray from the centre.
            let outward = simd_normalize(onSphere - dock.center)
            let camera = dock.center + outward * (radius * 1.6)
            let facing = try! #require(dock.coordinate(facing: camera))
            #expect(abs(facing.latitude - target.latitude) < 1e-3)
            let delta = abs(facing.longitude - target.longitude)
            #expect(min(delta, 360 - delta) < 1e-3)
        }
    }

    @Test("The globe's own centre names no coordinate")
    func centreHasNoDirection() {
        let dock = GlobeDock(coordinate: samples[0], radius: radius)
        #expect(dock.coordinate(facing: dock.center) == nil)
    }

    // MARK: - The matrix

    @Test("The matrix is the rotation and the drop, in that order")
    func matrixAgreesWithItsParts() {
        let dock = GlobeDock(coordinate: samples[2], radius: radius)
        let point = GlobeGeometry.position(for: samples[3], radius: radius)
        let throughMatrix = dock.matrix * SIMD4<Float>(point, 1)
        let throughParts = dock.dioramaPoint(for: samples[3])
        #expect(simd_length(throughMatrix.xyz - throughParts) < 1e-4)
        #expect(abs(throughMatrix.w - 1) < 1e-5)
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
