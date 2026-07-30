import Foundation
import Testing
import simd
@testable import Maquette

/// The globe's invariants.
///
/// These are the ones that fail invisibly. A sphere with inverted winding still looks like a sphere
/// until you get inside it, a mirrored texture still looks like the Earth until you go looking for
/// a continent whose shape you know, and rows spaced in latitude rather than in Mercator produce a
/// globe that is wrong by a few hundred kilometres in the mid-latitudes and by nothing at all at the
/// equator, which is exactly where anyone would check it.
@Suite("Globe geometry")
struct GlobeTests {
    // MARK: - The Mapping

    @Test("A coordinate survives the trip out to the sphere and back")
    func coordinateRoundTrips() {
        let samples = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 37.7749, longitude: -122.4194),
            Coordinate(latitude: -33.8688, longitude: 151.2093),
            Coordinate(latitude: 78.2232, longitude: 15.6267),
            Coordinate(latitude: 51.4779, longitude: 0.0015),
        ]

        for sample in samples {
            let position = GlobeGeometry.position(for: sample, radius: 0.5)
            let back = try! #require(GlobeGeometry.coordinate(forDirection: position))
            #expect(abs(back.latitude - sample.latitude) < 1e-4)
            #expect(abs(back.longitude - sample.longitude) < 1e-4)
        }
    }

    @Test("The frame puts the prime meridian on +Z and 90 east on +X")
    func frameMatchesTheCameraController() {
        // CameraController orbits with x = d·cos(e)·sin(a), z = d·cos(e)·cos(a). Sharing the
        // convention is what makes its azimuth a longitude and its elevation a latitude, which the
        // transition work will lean on.
        let nullIsland = GlobeGeometry.direction(for: Coordinate(latitude: 0, longitude: 0))
        #expect(simd_distance(nullIsland, SIMD3(0, 0, 1)) < 1e-6)

        let east = GlobeGeometry.direction(for: Coordinate(latitude: 0, longitude: 90))
        #expect(simd_distance(east, SIMD3(1, 0, 0)) < 1e-6)

        let northPole = GlobeGeometry.direction(for: Coordinate(latitude: 90, longitude: 0))
        #expect(simd_distance(northPole, SIMD3(0, 1, 0)) < 1e-6)
    }

    @Test("A zero direction has no coordinate rather than a plausible one")
    func originHasNoCoordinate() {
        #expect(GlobeGeometry.coordinate(forDirection: .zero) == nil)
    }

    @Test("North is at the top of the texture, not the bottom")
    func textureVIsNotFlipped() {
        // The trap this library has now hit in GLBParser, TerrainHeightField and TerracePalette: the
        // mosaic is drawn north-up and RealityKit counts texture rows from the bottom, so V has to be
        // inverted. A globe that got this wrong would still be a globe, with Antarctica on top.
        let north = GlobeGeometry.textureCoordinate(for: Coordinate(latitude: 60, longitude: 0))
        let south = GlobeGeometry.textureCoordinate(for: Coordinate(latitude: -60, longitude: 0))
        #expect(north.y > south.y)

        let equator = GlobeGeometry.textureCoordinate(for: Coordinate(latitude: 0, longitude: 0))
        #expect(abs(equator.y - 0.5) < 1e-6)
        #expect(abs(equator.x - 0.5) < 1e-6)

        let dateLine = GlobeGeometry.textureCoordinate(for: Coordinate(latitude: 0, longitude: -180))
        #expect(abs(dateLine.x) < 1e-6)
    }

    // MARK: - Mesh

    @Test("Every vertex sits on the sphere")
    func verticesAreOnTheSphere() {
        let radius: Float = 0.4
        let surface = GlobeGeometry.build(radius: radius, rows: 24, columns: 48)

        #expect(!surface.positions.isEmpty)
        for position in surface.positions {
            #expect(abs(simd_length(position) - radius) < 1e-4)
        }
        for normal in surface.normals {
            #expect(abs(simd_length(normal) - 1) < 1e-5)
        }
        #expect(surface.normals.count == surface.positions.count)
        #expect(surface.uvs.count == surface.positions.count)
    }

    @Test("Triangles wind so their faces point outward")
    func windingFacesOutward() {
        // Winding is invisible in vertex counts and completely visible on screen — a globe wound the
        // wrong way is culled to nothing, or shows you its inside.
        let surface = GlobeGeometry.build(radius: 0.4, rows: 24, columns: 48)
        var checked = 0

        for triangle in stride(from: 0, to: surface.indices.count, by: 3) {
            let a = surface.positions[Int(surface.indices[triangle])]
            let b = surface.positions[Int(surface.indices[triangle + 1])]
            let c = surface.positions[Int(surface.indices[triangle + 2])]

            let faceNormal = simd_cross(b - a, c - a)
            // Cap rings are degenerate quads — two of their corners coincide on the axis — so half of
            // each cap's triangles have no area and no facing to test.
            guard simd_length(faceNormal) > 1e-9 else { continue }

            let outward = (a + b + c) / 3
            #expect(simd_dot(simd_normalize(faceNormal), simd_normalize(outward)) > 0)
            checked += 1
        }

        #expect(checked > 0)
    }

    @Test("A vertex's texture coordinate names the place the vertex is")
    func uvsAgreeWithPositions() {
        // The mesh writes UVs from its own (u, m) parameters and positions from the coordinate those
        // parameters resolve to. If the two ever drift apart the texture slides off the geography,
        // so this closes the loop through the public mapping rather than through the parameters.
        let surface = GlobeGeometry.build(radius: 1, rows: 32, columns: 64)
        let perRing = 65

        // The Mercator band only: cap rings sit on the axis and carry a neighbour's V by design, and
        // the seam column is a duplicate at u = 1 whose coordinate reads back as −180°.
        for ring in 1...33 {
            for column in 0..<(perRing - 1) {
                let index = ring * perRing + column
                let coordinate = try! #require(
                    GlobeGeometry.coordinate(forDirection: surface.positions[index])
                )
                let expected = GlobeGeometry.textureCoordinate(for: coordinate)
                #expect(abs(expected.x - surface.uvs[index].x) < 1e-4)
                #expect(abs(expected.y - surface.uvs[index].y) < 1e-4)
            }
        }
    }

    @Test("The rows step in Mercator, not in latitude")
    func rowsAreMercatorSpaced() {
        // Evenly-spaced latitudes would put the halfway row at 42.5°, and the texture would then be
        // stretched over ground it does not belong to everywhere except the equator and the edges.
        let rows = 32
        let surface = GlobeGeometry.build(radius: 1, rows: rows, columns: 8)
        let perRing = 9

        let top = try! #require(GlobeGeometry.coordinate(forDirection: surface.positions[perRing]))
        #expect(abs(top.latitude - GlobeGeometry.mercatorLimitDegrees) < 1e-3)

        let bottomRing = 1 + rows
        let bottom = try! #require(
            GlobeGeometry.coordinate(forDirection: surface.positions[bottomRing * perRing])
        )
        #expect(abs(bottom.latitude + GlobeGeometry.mercatorLimitDegrees) < 1e-3)

        let middle = try! #require(
            GlobeGeometry.coordinate(forDirection: surface.positions[(1 + rows / 2) * perRing])
        )
        #expect(abs(middle.latitude) < 1e-6)

        // A quarter of the way down Mercator is not a quarter of the way down the latitude range.
        let quarter = try! #require(
            GlobeGeometry.coordinate(forDirection: surface.positions[(1 + rows / 4) * perRing])
        )
        #expect(abs(quarter.latitude - 66.5133) < 1e-3)
    }

    @Test("The poles are closed and carry the edge row's texture")
    func polesAreCapped() {
        let radius: Float = 1
        let rows = 16
        let surface = GlobeGeometry.build(radius: radius, rows: rows, columns: 32)
        let perRing = 33
        let ringCount = rows + 3

        for column in 0..<perRing {
            #expect(abs(surface.positions[column].y - radius) < 1e-5)
            let south = (ringCount - 1) * perRing + column
            #expect(abs(surface.positions[south].y + radius) < 1e-5)
        }

        // A cap shares its neighbour's V, so the edge pixel row smears radially into it instead of
        // pinching the whole texture into one point.
        #expect(surface.uvs[0].y == surface.uvs[perRing].y)
        #expect(surface.uvs[(ringCount - 1) * perRing].y == surface.uvs[(ringCount - 2) * perRing].y)

        // Each cap vertex keeps its own U, which is what a smear rather than a pinch requires.
        #expect(surface.uvs[0].x != surface.uvs[1].x)
    }

    @Test("The seam is duplicated so the texture does not run backwards")
    func seamIsDuplicated() {
        let columns = 24
        let surface = GlobeGeometry.build(radius: 1, rows: 8, columns: columns)
        let perRing = columns + 1

        // First and last vertex of a ring are the same place with different U — 0 and 1 — which is
        // the only way a wrapped texture can close without running the whole world back the other way
        // across the final column.
        let first = surface.positions[perRing]
        let last = surface.positions[perRing + columns]
        #expect(simd_distance(first, last) < 1e-5)
        #expect(abs(surface.uvs[perRing].x) < 1e-6)
        #expect(abs(surface.uvs[perRing + columns].x - 1) < 1e-6)
    }

    @Test("The mesh is the size the parameters ask for")
    func bufferSizesFollowTheParameters() {
        let rows = 10
        let columns = 20
        let surface = GlobeGeometry.build(radius: 1, rows: rows, columns: columns)

        let ringCount = rows + 3
        let perRing = columns + 1
        #expect(surface.positions.count == ringCount * perRing)
        #expect(surface.indices.count == (ringCount - 1) * columns * 6)
        #expect(surface.indices.allSatisfy { $0 < UInt32(surface.positions.count) })
    }

    @Test("Degenerate parameters still produce a closed mesh")
    func parametersAreFloored() {
        let surface = GlobeGeometry.build(radius: 1, rows: 0, columns: 0)
        #expect(surface.positions.count >= 4 * 4)
        #expect(!surface.indices.isEmpty)
        for position in surface.positions {
            #expect(abs(simd_length(position) - 1) < 1e-4)
        }
    }
}
