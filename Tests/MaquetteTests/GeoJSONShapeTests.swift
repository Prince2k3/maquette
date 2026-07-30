import CoreLocation
import Foundation
import Testing
import simd
@testable import Maquette

@Suite("GeoJSON Shape Tests")
struct GeoJSONShapeTests {
    private static let center = Coordinate(latitude: 36.1069, longitude: -112.1129)

    /// A rectangle in longitude/latitude, offset from a centre by whole degrees of each.
    private func ring(
        about middle: Coordinate = GeoJSONShapeTests.center,
        halfWidth: Double = 0.02,
        halfHeight: Double = 0.01
    ) -> LinearRing {
        LinearRing([
            Coordinate(longitude: middle.longitude - halfWidth, latitude: middle.latitude - halfHeight),
            Coordinate(longitude: middle.longitude + halfWidth, latitude: middle.latitude - halfHeight),
            Coordinate(longitude: middle.longitude + halfWidth, latitude: middle.latitude + halfHeight),
            Coordinate(longitude: middle.longitude - halfWidth, latitude: middle.latitude + halfHeight),
        ])
    }

    private func fanNormalPointsUp(_ boundary: DioramaBoundary) -> Bool {
        let vertices = boundary.vertices
        let a = SIMD3(vertices[0].x, 0, vertices[0].y)
        let b = SIMD3(vertices[1].x, 0, vertices[1].y)
        let c = SIMD3(vertices[2].x, 0, vertices[2].y)
        return simd_cross(b - a, c - a).y > 0
    }

    // MARK: - Resolution

    @Test("A ring about the frame's centre resolves about the origin")
    func ringResolvesAboutTheOrigin() {
        let frame = GeographicFrame(center: Self.center, radiusMeters: 5000)
        let boundary = DioramaBoundary.make(
            shape: .geoJSON(ring: ring()),
            extent: SIMD2(0.8, 0.8),
            frame: frame
        )

        #expect(boundary.vertices.count == 4)
        let middle = boundary.minCorner + boundary.extent / 2
        #expect(abs(middle.x) < 0.001)
        #expect(abs(middle.y) < 0.001)
    }

    @Test("The outline lands on the ground the chunk's own projection names")
    func resolutionMatchesTheChunksMapping() {
        // The mapping has to be *the* mapping: a boundary resolved through anything else drifts
        // against the terrain it cuts, and a cut edge a few metres off the city limit it names
        // still looks like a city limit.
        let frame = GeographicFrame(center: Self.center, radiusMeters: 5000)
        let extent = SIMD2<Float>(0.8, 0.8)
        let outline = ring()
        let boundary = DioramaBoundary.make(shape: .geoJSON(ring: outline), extent: extent, frame: frame)

        // Checked at three zooms because the resolution happens at a fixed reference zoom while the
        // terrain is fetched at whatever the configuration asked for. A tile-space delta divided by
        // the metres-per-tile it was measured in is the same ground either way, and if it were not,
        // the outline would silently be the wrong size for the ground it cuts.
        for zoom in [8, 12, 16] {
            let anchor = TerrainAnchor(
                centeredOn: Self.center,
                zoom: zoom,
                extent: extent,
                radiusMeters: 5000
            )
            for coordinate in outline.open {
                let point = anchor.dioramaPoint(for: coordinate)
                let expected = SIMD2(Float(point.x), Float(point.y))
                let nearest = boundary.vertices.min {
                    simd_distance($0, expected) < simd_distance($1, expected)
                }
                guard let nearest else {
                    Issue.record("The boundary has no vertices")
                    return
                }
                // Sub-millimetre on an 0.8 m chunk, at every zoom.
                #expect(simd_distance(nearest, expected) < 0.0005)
            }
        }
    }

    @Test("The outline is at true scale, not fitted to the chunk")
    func outlineKeepsTrueScale() {
        // Twice the radius over the same extent is half the diorama metres per real metre, so the
        // same ground comes out half the size. An outline stretched to fill the chunk would be
        // invariant here — and would put the cut edge where the boundary does not run.
        let near = DioramaBoundary.make(
            shape: .geoJSON(ring: ring()),
            extent: SIMD2(0.8, 0.8),
            frame: GeographicFrame(center: Self.center, radiusMeters: 5000)
        )
        let far = DioramaBoundary.make(
            shape: .geoJSON(ring: ring()),
            extent: SIMD2(0.8, 0.8),
            frame: GeographicFrame(center: Self.center, radiusMeters: 10000)
        )

        #expect(abs(near.extent.x - far.extent.x * 2) < 0.001)
        #expect(abs(near.extent.y - far.extent.y * 2) < 0.001)
    }

    @Test("An off-centre outline is drawn off-centre")
    func offsetOutlineIsNotRecentred() {
        // Where the ground is, is where the outline goes. Re-centring would silently move the cut
        // edge onto terrain the boundary says nothing about.
        let east = Coordinate(latitude: Self.center.latitude, longitude: Self.center.longitude + 0.03)
        let boundary = DioramaBoundary.make(
            shape: .geoJSON(ring: ring(about: east)),
            extent: SIMD2(0.8, 0.8),
            frame: GeographicFrame(center: Self.center, radiusMeters: 5000)
        )

        let middle = boundary.minCorner + boundary.extent / 2
        #expect(middle.x > 0.1, "An outline east of the centre belongs in +X")
        #expect(abs(middle.y) < 0.001)
        #expect(!boundary.contains(SIMD2(0, 0)), "The origin is no longer inside the outline")
    }

    @Test("North is -Z and east is +X")
    func axesFollowTheDioramaConvention() {
        let frame = GeographicFrame(center: Self.center, radiusMeters: 5000)
        let anchor = frame.anchor(spanning: SIMD2(0.8, 0.8))

        let north = anchor.dioramaPoint(for: Coordinate(
            latitude: Self.center.latitude + 0.01,
            longitude: Self.center.longitude
        ))
        let east = anchor.dioramaPoint(for: Coordinate(
            latitude: Self.center.latitude,
            longitude: Self.center.longitude + 0.01
        ))

        #expect(north.y < 0)
        #expect(east.x > 0)
    }

    // MARK: - Winding and shape

    @Test("Winding is normalized whichever way the ring runs")
    func windingIsNormalized() {
        let counterclockwise = ring()
        let clockwise = counterclockwise.reversed
        #expect(counterclockwise.isClockwise != clockwise.isClockwise)

        let frame = GeographicFrame(center: Self.center, radiusMeters: 5000)
        for outline in [counterclockwise, clockwise] {
            let boundary = DioramaBoundary.make(
                shape: .geoJSON(ring: outline),
                extent: SIMD2(0.8, 0.8),
                frame: frame
            )
            #expect(fanNormalPointsUp(boundary))
        }
    }

    @Test("A concave outline stays concave")
    func concaveOutlineSurvives() {
        // The reason a geographic outline is worth having at all: the clip is exact, so a real
        // boundary's notches are cut rather than filled in.
        let lon = Self.center.longitude
        let lat = Self.center.latitude
        let ell = LinearRing([
            Coordinate(longitude: lon - 0.02, latitude: lat - 0.02),
            Coordinate(longitude: lon + 0.02, latitude: lat - 0.02),
            Coordinate(longitude: lon + 0.02, latitude: lat),
            Coordinate(longitude: lon, latitude: lat),
            Coordinate(longitude: lon, latitude: lat + 0.02),
            Coordinate(longitude: lon - 0.02, latitude: lat + 0.02),
        ])
        let boundary = DioramaBoundary.make(
            shape: .geoJSON(ring: ell),
            extent: SIMD2(0.8, 0.8),
            frame: GeographicFrame(center: Self.center, radiusMeters: 5000)
        )

        #expect(boundary.vertices.count == 6)
        #expect(fanNormalPointsUp(boundary))

        let quarter = boundary.extent.x / 4
        // The notch is north-east of the centre, which in diorama space is +X and -Z.
        #expect(!boundary.contains(SIMD2(quarter, -quarter)))
        #expect(boundary.contains(SIMD2(-quarter, -quarter)))
        #expect(boundary.contains(SIMD2(quarter, quarter)))
    }

    @Test("With no frame the outline is fitted to the extent")
    func unframedOutlineFillsTheExtent() {
        let boundary = DioramaBoundary.make(
            shape: .geoJSON(ring: ring(halfWidth: 0.02, halfHeight: 0.005)),
            extent: SIMD2(1.0, 1.0)
        )

        #expect(abs(boundary.extent.x - 1.0) < 0.01, "The longer side fills the extent")
        #expect(boundary.extent.y < boundary.extent.x, "The shorter side keeps its proportion")
    }

    // MARK: - Reading real documents

    @Test("The shape is taken from whatever GeoJSON holds a polygon")
    func shapeFromGeoJSONObjects() throws {
        let outline = ring()
        let hole = ring(halfWidth: 0.005, halfHeight: 0.002)
        let polygon = Polygon(exterior: outline, holes: [hole])

        // A polygon's holes are dropped, not punched out — so the exterior is what comes back.
        guard case .geoJSON(let fromPolygon)? = DioramaShape.geoJSON(polygon) else {
            Issue.record("Expected a polygon to make a shape")
            return
        }
        #expect(fromPolygon == outline)

        guard case .geoJSON(let fromCollection)? = DioramaShape.geoJSON(
            Geometry.geometryCollection([
                .point(Point(Self.center)),
                .multiPolygon(MultiPolygon([polygon])),
            ])
        ) else {
            Issue.record("Expected a nested multi-polygon to be found")
            return
        }
        #expect(fromCollection == outline)

        let feature = Feature(geometry: .polygon(polygon), id: .string("park"))
        #expect(DioramaShape.geoJSON(feature) != nil)
        #expect(DioramaShape.geoJSON(FeatureCollection([feature])) != nil)

        // Nothing to cut to is nil rather than a guess at one.
        #expect(DioramaShape.geoJSON(Geometry.point(Point(Self.center))) == nil)
        #expect(DioramaShape.geoJSON(FeatureCollection([])) == nil)
    }

    @Test("A decoded boundary file configures a diorama on its own")
    func decodedDocumentBecomesAConfiguration() throws {
        let json = """
        {
          "type": "FeatureCollection",
          "features": [
            {
              "type": "Feature",
              "id": "park",
              "geometry": {
                "type": "Polygon",
                "coordinates": [[
                  [-112.14, 36.09], [-112.08, 36.09], [-112.08, 36.13],
                  [-112.14, 36.13], [-112.14, 36.09]
                ]]
              },
              "properties": {"name": "A park"}
            }
          ]
        }
        """
        let collection = try JSONDecoder().decode(FeatureCollection.self, from: Data(json.utf8))
        let configuration = try #require(DioramaConfiguration(outline: collection))

        // The outline decides where the diorama is and how much ground it fetches.
        #expect(abs(configuration.center.longitude - -112.11) < 0.001)
        #expect(abs(configuration.center.latitude - 36.11) < 0.01)

        let boundary = configuration.boundary
        #expect(boundary.vertices.count == 4)
        // Padding is what keeps the cut edge off the edge of the fetched region.
        #expect(boundary.extent.x < configuration.physicalDiameter)
        #expect(
            abs(boundary.extent.x - configuration.physicalDiameter / 1.05) < 0.005,
            "The longer side fills the diameter less the 5% padding"
        )
        #expect(fanNormalPointsUp(boundary))

        // A document with no polygon in it has no outline to be cut to.
        #expect(DioramaConfiguration(outline: FeatureCollection([])) == nil)
    }

    @Test("A geographic outline reports the diameter as its scale reference")
    func horizontalExtentIsTheScaleReference() throws {
        let configuration = DioramaConfiguration(
            center: Self.center.clLocationCoordinate,
            radiusMeters: 5000,
            shape: .geoJSON(ring: ring()),
            physicalDiameter: 0.8
        )

        // The extent says how much diorama the fetched radius spans; the outline's own footprint is
        // whatever the ground works out to, and is smaller.
        #expect(configuration.horizontalExtent == SIMD2(0.8, 0.8))
        #expect(configuration.boundary.extent.x < 0.8)
        #expect(configuration.boundary.extent.x > 0)
    }

    // MARK: - Framing

    @Test("A fitted frame holds the whole outline")
    func fittedFrameHoldsTheOutline() throws {
        let wide = ring(halfWidth: 0.03, halfHeight: 0.01)
        let outline = Geometry.polygon(Polygon(exterior: wide))
        let frame = try #require(GeographicFrame(fitting: outline, padding: 0))

        // Fitted with no padding, the outline's longer side is exactly the chunk, centred on it.
        let boundary = DioramaBoundary.make(
            shape: .geoJSON(ring: wide),
            extent: SIMD2(1.0, 1.0),
            frame: frame
        )
        #expect(abs(boundary.extent.x - 1.0) < 0.005)
        let middle = boundary.minCorner + boundary.extent / 2
        #expect(abs(middle.x) < 0.005)
        #expect(abs(middle.y) < 0.005)

        // Padding leaves room between the cut edge and the edge of the fetched ground.
        let padded = try #require(GeographicFrame(fitting: outline, padding: 0.25))
        #expect(abs(padded.radiusMeters - frame.radiusMeters * 1.25) < 0.001)

        // Nothing to measure is nil rather than a degenerate frame.
        #expect(GeographicFrame(fitting: .point(Point(Self.center))) == nil)
    }
}
