import Foundation
import Testing
@testable import Maquette

@Suite("Turf Tests")
struct TurfTests {
    /// One degree of latitude on Turf's sphere, in metres. Every measurement below is scaled from
    /// this rather than from a remembered figure, so a change of earth radius shows up as one
    /// failing constant instead of a dozen mysterious ones.
    static let metersPerDegree = Turf.earthRadiusMeters * .pi / 180

    // MARK: - Distance

    @Test("A degree of latitude measures the sphere it was defined on")
    func degreeOfLatitude() {
        let measured = Turf.distance(
            from: Coordinate(latitude: 0, longitude: 0),
            to: Coordinate(latitude: 1, longitude: 0)
        )
        #expect(abs(measured - Self.metersPerDegree) < 0.01)
    }

    @Test("Distances come back in metres, not kilometres")
    func distanceIsInMeters() {
        // The single most consequential departure from Turf.js, and the one that would be silent:
        // London to Paris is ~344 km, so a value near 344 means the units slipped.
        let london = Coordinate(latitude: 51.5074, longitude: -0.1278)
        let paris = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let measured = Turf.distance(from: london, to: paris)
        #expect(measured > 340_000 && measured < 348_000)
    }

    @Test("A coordinate is no distance from itself")
    func zeroDistance() {
        let place = Coordinate(latitude: 46.85, longitude: -121.76)
        #expect(Turf.distance(from: place, to: place) < 1e-9)
    }

    // MARK: - Direction

    @Test("Bearings name the compass directions they should")
    func cardinalBearings() {
        let origin = Coordinate(latitude: 0, longitude: 0)
        #expect(abs(Turf.bearing(from: origin, to: Coordinate(latitude: 1, longitude: 0)) - 0) < 1e-9)
        #expect(abs(Turf.bearing(from: origin, to: Coordinate(latitude: 0, longitude: 1)) - 90) < 1e-9)
        #expect(abs(Turf.bearing(from: origin, to: Coordinate(latitude: -1, longitude: 0)) - 180) < 1e-9)
        #expect(abs(Turf.bearing(from: origin, to: Coordinate(latitude: 0, longitude: -1)) + 90) < 1e-9)
    }

    @Test("A great circle's bearing turns between its ends")
    func finalBearingDiffers() {
        // Two points at the same latitude sit symmetrically about the path's middle meridian, so
        // the bearing leaving is as far below due east as the bearing arriving is above it.
        let from = Coordinate(latitude: 60, longitude: 0)
        let to = Coordinate(latitude: 60, longitude: 60)
        let initial = Turf.bearing(from: from, to: to)
        let final = Turf.finalBearing(from: from, to: to)

        #expect(initial < 90)
        #expect(final > 90)
        #expect(abs(initial + final - 180) < 1e-9)
    }

    // MARK: - Destination

    @Test("Travelling a distance on a bearing lands that distance away on that bearing")
    func destinationRoundTrip() {
        let origin = Coordinate(latitude: 36.0544, longitude: -112.1401)
        for bearing in stride(from: -180.0, through: 180.0, by: 30) {
            let arrived = Turf.destination(from: origin, meters: 5_000, bearing: bearing)
            #expect(abs(Turf.distance(from: origin, to: arrived) - 5_000) < 0.001)
            #expect(abs(Turf.normalizedBearing(Turf.bearing(from: origin, to: arrived) - bearing)) < 1e-6)
        }
    }

    @Test("A destination keeps the altitude it set out with")
    func destinationKeepsAltitude() {
        let origin = Coordinate(latitude: 46.85, longitude: -121.76, altitude: 4_392)
        #expect(Turf.destination(from: origin, meters: 1_000, bearing: 45).altitude == 4_392)
    }

    @Test("A journey east across the antimeridian wraps rather than running off the scale")
    func destinationWrapsLongitude() {
        let origin = Coordinate(latitude: 0, longitude: 179.9)
        let arrived = Turf.destination(from: origin, meters: 200_000, bearing: 90)
        #expect(arrived.longitude < 0)
        #expect(arrived.longitude > -180)
        #expect(abs(Turf.distance(from: origin, to: arrived) - 200_000) < 0.001)
    }

    @Test("A midpoint sits the same distance from both ends")
    func midpointIsHalfway() {
        let a = Coordinate(latitude: 51.5074, longitude: -0.1278)
        let b = Coordinate(latitude: 48.8566, longitude: 2.3522)
        let middle = Turf.midpoint(a, b)
        let toA = Turf.distance(from: middle, to: a)
        let toB = Turf.distance(from: middle, to: b)
        #expect(abs(toA - toB) < 0.001)
        #expect(abs(toA + toB - Turf.distance(from: a, to: b)) < 0.001)
    }

    // MARK: - Length and traversal

    @Test("A line's length is the sum of its segments")
    func lineLength() {
        let line = LineString([
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 1, longitude: 0),
            Coordinate(latitude: 2, longitude: 0),
        ])
        #expect(abs(Turf.length(of: line) - 2 * Self.metersPerDegree) < 0.02)
    }

    @Test("A single position has no length, and a polygon's length is its perimeter")
    func lengthByGeometry() {
        #expect(Turf.length(of: .point(Point(Coordinate(latitude: 1, longitude: 1)))) == 0)

        let polygon = Polygon(Self.square)
        let perimeter = Turf.length(of: .polygon(polygon))
        // Four sides of roughly a degree each — the two running east/west shrink by cos(latitude),
        // so this is a range rather than an equality.
        #expect(perimeter > 3.9 * Self.metersPerDegree)
        #expect(perimeter < 4.01 * Self.metersPerDegree)
    }

    @Test("A point along a line lands where the distance says")
    func alongTheLine() throws {
        let line = LineString([
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 2, longitude: 0),
        ])
        let halfway = try #require(Turf.along(line, meters: Self.metersPerDegree))
        #expect(abs(halfway.latitude - 1) < 1e-6)
        #expect(abs(halfway.longitude) < 1e-6)
    }

    @Test("Asking past either end of a line stops at that end")
    func alongClamps() throws {
        // Extrapolating instead would fly a route preview off its own destination.
        let line = LineString([
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 2, longitude: 0),
        ])
        #expect(try #require(Turf.along(line, meters: -50)).latitude == 0)
        #expect(try #require(Turf.along(line, meters: 1e9)).latitude == 2)
    }

    // MARK: - Area

    @Test("A degree square's area matches the sphere's own integral")
    func degreeSquareArea() {
        // R² · Δλ · (sin φ₂ − sin φ₁), the closed form for a lat/lon rectangle on a sphere.
        let expected = Turf.earthRadiusMeters * Turf.earthRadiusMeters
            * (.pi / 180) * (sin(1 * .pi / 180) - sin(0.0))
        let measured = Turf.area(of: Polygon(Self.square))
        #expect(abs(measured - expected) / expected < 0.001)
    }

    @Test("A shoelace over degrees would understate a polygon far from the equator")
    func areaIsSphericalNotPlanar() {
        // The same one-degree square measured at 60°N covers about half the ground it does at the
        // equator, because a degree of longitude is half as wide there. A planar shoelace over
        // lon/lat reports the same number for both, which is the mistake this guards.
        let equator = Turf.area(of: Polygon(Self.square))
        let far = Turf.area(of: Polygon(Self.square.map {
            Coordinate(latitude: $0.latitude + 60, longitude: $0.longitude)
        }))
        #expect(far < equator)
        #expect(abs(far / equator - cos(60.5 * .pi / 180)) < 0.01)
    }

    @Test("Holes come out of the area they sit in")
    func holesSubtract() {
        let hole = LinearRing([
            Coordinate(latitude: 0.25, longitude: 0.25),
            Coordinate(latitude: 0.25, longitude: 0.75),
            Coordinate(latitude: 0.75, longitude: 0.75),
            Coordinate(latitude: 0.75, longitude: 0.25),
        ])
        let solid = Polygon(Self.square)
        let holed = Polygon(exterior: LinearRing(Self.square), holes: [hole])
        let holeArea = Turf.area(of: Polygon(rings: [hole]))

        #expect(holeArea > 0)
        #expect(abs(Turf.area(of: holed) - (Turf.area(of: solid) - holeArea)) < 1)
    }

    @Test("Winding does not change how much ground a ring covers")
    func areaIgnoresWinding() {
        let ring = LinearRing(Self.square)
        #expect(
            abs(Turf.area(of: Polygon(rings: [ring])) - Turf.area(of: Polygon(rings: [ring.reversed])))
                < 1e-6
        )
    }

    @Test("A line encloses nothing")
    func linesHaveNoArea() {
        #expect(Turf.area(of: .lineString(LineString(Self.square))) == 0)
    }

    // MARK: - Centres and extents

    @Test("A centre is the middle of the extent, a centroid the mean of the vertices")
    func centreAndCentroidDiffer() throws {
        // One end of the line carries most of the vertices, which is exactly the case where the
        // two answers come apart — and why "point the camera at this" wants the centre.
        let clustered = Geometry.lineString(LineString([
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 0.1),
            Coordinate(latitude: 0, longitude: 0.2),
            Coordinate(latitude: 0, longitude: 10),
        ]))
        let center = try #require(Turf.center(of: clustered))
        let centroid = try #require(Turf.centroid(of: clustered))
        #expect(abs(center.longitude - 5) < 1e-9)
        #expect(centroid.longitude < 3)
    }

    @Test("A collection's extent covers every feature in it")
    func collectionExtent() throws {
        let collection = FeatureCollection([
            .point(Coordinate(latitude: -1, longitude: -2)),
            .line([Coordinate(latitude: 3, longitude: 4), Coordinate(latitude: 1, longitude: 1)]),
        ])
        let bounds = try #require(Turf.boundingBox(of: collection))
        #expect(bounds.west == -2 && bounds.south == -1 && bounds.east == 4 && bounds.north == 3)
    }

    @Test("A feature's extent is measured, not taken from what the document claimed")
    func extentIsMeasured() throws {
        // A declared bbox is whatever the writer put there; it may be stale, wrong, or absent.
        let feature = Feature(
            geometry: .point(Point(Coordinate(latitude: 5, longitude: 5))),
            boundingBox: GeographicBounds(west: -180, south: -90, east: 180, north: 90)
        )
        let measured = try #require(Turf.boundingBox(of: feature))
        #expect(measured.west == 5 && measured.east == 5)
    }

    // MARK: - Containment

    @Test("A polygon contains what is inside it and not what is outside")
    func pointInPolygon() {
        let square = Polygon(Self.square)
        #expect(Turf.contains(Coordinate(latitude: 0.5, longitude: 0.5), in: square))
        #expect(!Turf.contains(Coordinate(latitude: 0.5, longitude: 1.5), in: square))
        #expect(!Turf.contains(Coordinate(latitude: 2, longitude: 0.5), in: square))
    }

    @Test("A point on the border belongs to both sides unless the boundary is excluded")
    func boundaryRule() {
        // Two regions sharing a border: with the default, a point on it is inside both, which is
        // right for "which regions touch here" and wrong for "which region is this in".
        let square = Polygon(Self.square)
        let onEdge = Coordinate(latitude: 0.5, longitude: 0)
        let onVertex = Coordinate(latitude: 0, longitude: 0)

        #expect(Turf.contains(onEdge, in: square))
        #expect(!Turf.contains(onEdge, in: square, ignoringBoundary: true))
        #expect(Turf.contains(onVertex, in: square))
        #expect(!Turf.contains(onVertex, in: square, ignoringBoundary: true))
    }

    @Test("A hole is not part of the polygon it is cut from")
    func holesAreNotContained() {
        let hole = LinearRing([
            Coordinate(latitude: 0.25, longitude: 0.25),
            Coordinate(latitude: 0.25, longitude: 0.75),
            Coordinate(latitude: 0.75, longitude: 0.75),
            Coordinate(latitude: 0.75, longitude: 0.25),
        ])
        let holed = Polygon(exterior: LinearRing(Self.square), holes: [hole])

        #expect(!Turf.contains(Coordinate(latitude: 0.5, longitude: 0.5), in: holed))
        #expect(Turf.contains(Coordinate(latitude: 0.1, longitude: 0.1), in: holed))
    }

    @Test("A concave polygon does not swallow the bay it wraps around")
    func concaveContainment() {
        // A C shape: the notch is inside the bounding box and outside the polygon, which is what
        // separates a real crossing test from a bounds check.
        let cShape = Polygon([
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 3),
            Coordinate(latitude: 1, longitude: 3),
            Coordinate(latitude: 1, longitude: 1),
            Coordinate(latitude: 2, longitude: 1),
            Coordinate(latitude: 2, longitude: 3),
            Coordinate(latitude: 3, longitude: 3),
            Coordinate(latitude: 3, longitude: 0),
        ])
        #expect(Turf.contains(Coordinate(latitude: 0.5, longitude: 0.5), in: cShape))
        #expect(Turf.contains(Coordinate(latitude: 1.5, longitude: 0.5), in: cShape))
        #expect(!Turf.contains(Coordinate(latitude: 1.5, longitude: 2), in: cShape))
    }

    @Test("Only areas contain anything")
    func nonAreasContainNothing() {
        let inside = Coordinate(latitude: 0.5, longitude: 0.5)
        #expect(!Turf.contains(inside, in: .lineString(LineString(Self.square))))
        #expect(!Turf.contains(inside, in: .point(Point(inside))))
        #expect(Turf.contains(inside, in: .multiPolygon(MultiPolygon([Polygon(Self.square)]))))
    }

    // MARK: - Point on line

    @Test("The nearest point on a line is the foot of the perpendicular")
    func nearestPointOnLine() throws {
        let line = LineString([
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 1),
        ])
        let query = Coordinate(latitude: 0.001, longitude: 0.5)
        let nearest = try #require(Turf.nearestPoint(on: line, to: query))

        #expect(nearest.segmentIndex == 0)
        #expect(abs(nearest.coordinate.longitude - 0.5) < 1e-6)
        #expect(abs(nearest.coordinate.latitude) < 1e-6)
        #expect(abs(nearest.distanceMeters - 0.001 * Self.metersPerDegree) < 0.1)
        #expect(abs(nearest.locationMeters - 0.5 * Turf.length(of: line)) < 0.1)
    }

    @Test("A query past the end of a line clamps to the end, not the extension")
    func nearestPointClamps() throws {
        let line = LineString([
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 1),
        ])
        let nearest = try #require(
            Turf.nearestPoint(on: line, to: Coordinate(latitude: 0, longitude: 5))
        )
        #expect(abs(nearest.coordinate.longitude - 1) < 1e-6)
    }

    @Test("The closest of several segments is the one that wins")
    func nearestPointPicksItsSegment() throws {
        let line = LineString([
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 1),
            Coordinate(latitude: 1, longitude: 1),
        ])
        let nearest = try #require(
            Turf.nearestPoint(on: line, to: Coordinate(latitude: 0.9, longitude: 1.001))
        )
        #expect(nearest.segmentIndex == 1)
    }

    @Test("Being on a line is a distance question, not an exact-arithmetic one")
    func pointOnLineIsToleranced() {
        // A coordinate that came off the line and back through a float misses it in the last
        // decimal place, which Turf's exact collinearity test calls "not on the line".
        let line = LineString([
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 0, longitude: 1),
        ])
        let nearlyOn = Coordinate(latitude: 1e-9, longitude: 0.5)
        let clearlyOff = Coordinate(latitude: 0.01, longitude: 0.5)

        #expect(Turf.isPoint(nearlyOn, on: line))
        #expect(!Turf.isPoint(clearlyOff, on: line))
        #expect(Turf.isPoint(clearlyOff, on: line, toleranceMeters: 2_000))
    }

    // MARK: - Fixtures

    /// A degree square at the origin.
    static let square = [
        Coordinate(latitude: 0, longitude: 0),
        Coordinate(latitude: 0, longitude: 1),
        Coordinate(latitude: 1, longitude: 1),
        Coordinate(latitude: 1, longitude: 0),
    ]
}
