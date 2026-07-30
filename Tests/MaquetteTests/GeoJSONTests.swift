import Foundation
import Testing
@testable import Maquette

@Suite("GeoJSON Tests")
struct GeoJSONTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Geometries

    @Test("A point round-trips through its GeoJSON form")
    func pointRoundTrip() throws {
        let point = Point(Coordinate(latitude: 46.8523, longitude: -121.7603))
        let decoded = try decoder.decode(Point.self, from: encoder.encode(point))
        #expect(decoded == point)
    }

    @Test("Every geometry type decodes through the Geometry enum")
    func allGeometryTypes() throws {
        let cases: [(String, Geometry)] = [
            ("Point", .point(Point(Coordinate(latitude: 1, longitude: 2)))),
            ("MultiPoint", .multiPoint(MultiPoint([Coordinate(latitude: 1, longitude: 2)]))),
            ("LineString", .lineString(LineString([
                Coordinate(latitude: 0, longitude: 0),
                Coordinate(latitude: 1, longitude: 1),
            ]))),
            ("MultiLineString", .multiLineString(MultiLineString(coordinates: [[
                Coordinate(latitude: 0, longitude: 0),
                Coordinate(latitude: 1, longitude: 1),
            ]]))),
            ("Polygon", .polygon(Polygon(Self.square))),
            ("MultiPolygon", .multiPolygon(MultiPolygon([Polygon(Self.square)]))),
            ("GeometryCollection", .geometryCollection([
                .point(Point(Coordinate(latitude: 1, longitude: 2))),
                .polygon(Polygon(Self.square)),
            ])),
        ]

        for (name, geometry) in cases {
            let data = try encoder.encode(geometry)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(object?["type"] as? String == name)
            #expect(try decoder.decode(Geometry.self, from: data) == geometry)
        }
    }

    @Test("A geometry decoded as the wrong concrete type is rejected")
    func wrongConcreteType() {
        let json = Data(#"{"type":"Point","coordinates":[1,2]}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LineString.self, from: json)
        }
    }

    // MARK: - Rings

    @Test("A ring closes itself")
    func ringCloses() {
        let ring = LinearRing(Self.square)
        #expect(ring.coordinates.count == Self.square.count + 1)
        #expect(ring.coordinates.first == ring.coordinates.last)
        #expect(ring.open.count == Self.square.count)
    }

    @Test("A ring that arrives closed is not closed twice")
    func alreadyClosedRing() {
        let closed = Self.square + [Self.square[0]]
        #expect(LinearRing(closed).coordinates.count == closed.count)
    }

    @Test("Winding is reported, not corrected")
    func windingIsReported() {
        // The square runs counterclockwise in lon/lat, which is what RFC 7946 asks of an exterior
        // ring — but a ring wound the other way is kept as it came, because real data is full of
        // both and the spec tells parsers not to reject them.
        let counterclockwise = LinearRing(Self.square)
        #expect(!counterclockwise.isClockwise)
        #expect(counterclockwise.reversed.isClockwise)
        #expect(counterclockwise.reversed.coordinates.count == counterclockwise.coordinates.count)
    }

    @Test("A ring too short to bound anything is rejected on decode")
    func shortRingRejected() {
        let json = Data(#"{"type":"Polygon","coordinates":[[[0,0],[1,1]]]}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Polygon.self, from: json)
        }
    }

    @Test("A polygon whose ring was written unclosed is accepted and closed")
    func unclosedRingAccepted() throws {
        let json = Data(#"{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,1]]]}"#.utf8)
        let polygon = try JSONDecoder().decode(Polygon.self, from: json)
        let exterior = try #require(polygon.exterior)
        #expect(exterior.coordinates.count == 5)
        #expect(exterior.coordinates.first == exterior.coordinates.last)
    }

    @Test("Holes come after the exterior ring")
    func holesFollowExterior() {
        let hole = LinearRing([
            Coordinate(latitude: 0.25, longitude: 0.25),
            Coordinate(latitude: 0.25, longitude: 0.75),
            Coordinate(latitude: 0.75, longitude: 0.75),
        ])
        let polygon = Polygon(exterior: LinearRing(Self.square), holes: [hole])
        #expect(polygon.rings.count == 2)
        #expect(polygon.exterior == LinearRing(Self.square))
        #expect(Array(polygon.holes) == [hole])
    }

    // MARK: - Features

    @Test("A feature round-trips with its identifier and properties")
    func featureRoundTrip() throws {
        let feature = Feature(
            geometry: .point(Point(Coordinate(latitude: 46.85, longitude: -121.76))),
            id: "rainier",
            properties: ["name": "Mount Rainier", "elevation": 4392, "volcanic": true, "note": nil]
        )
        let decoded = try decoder.decode(Feature.self, from: encoder.encode(feature))
        #expect(decoded == feature)
        #expect(decoded[property: "elevation"]?.doubleValue == 4392)
        #expect(decoded[property: "volcanic"]?.boolValue == true)
        #expect(decoded[property: "note"] == .null)
    }

    @Test("A numeric feature id stays numeric")
    func numericIdentifier() throws {
        let feature = Feature(geometry: nil, id: 42)
        let decoded = try decoder.decode(Feature.self, from: encoder.encode(feature))
        #expect(decoded.id == .number(42))
    }

    @Test("A null geometry and null properties are written, not dropped")
    func nullMembersWritten() throws {
        let data = try encoder.encode(Feature(geometry: nil))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
        )
        #expect(object.keys.contains("geometry"))
        #expect(object.keys.contains("properties"))
    }

    @Test("A document decodes whatever form it happens to take")
    func anyDocumentForm() throws {
        let bareGeometry = Data(#"{"type":"Point","coordinates":[1,2]}"#.utf8)
        let feature = Data(#"{"type":"Feature","geometry":null,"properties":null}"#.utf8)
        let collection = Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)

        #expect(try decoder.decode(GeoJSONObject.self, from: bareGeometry).features.count == 1)
        #expect(try decoder.decode(GeoJSONObject.self, from: feature).features.count == 1)
        #expect(try decoder.decode(GeoJSONObject.self, from: collection).features.isEmpty)
    }

    @Test("A collection reads as a collection of its features")
    func collectionIsACollection() {
        let collection = FeatureCollection([
            .point(Coordinate(latitude: 1, longitude: 1)),
            .point(Coordinate(latitude: 2, longitude: 2)),
        ])
        #expect(collection.count == 2)
        #expect(collection.first?.geometry == .point(Point(Coordinate(latitude: 1, longitude: 1))))
    }

    // MARK: - Bounds

    @Test("A bbox round-trips in both its four- and six-value forms")
    func boundsRoundTrip() throws {
        let flat = GeographicBounds(west: -10, south: -5, east: 10, north: 5)
        #expect(try decoder.decode(GeographicBounds.self, from: encoder.encode(flat)) == flat)

        let tall = GeographicBounds(
            west: -10, south: -5, east: 10, north: 5,
            minimumAltitude: 100, maximumAltitude: 900
        )
        let data = try encoder.encode(tall)
        // All axes of the southwesterly point, then all axes of the northeasterly one — so the
        // altitudes land in the middle and at the end rather than in a pair.
        #expect(try decoder.decode([Double].self, from: data) == [-10, -5, 100, 10, 5, 900])
        #expect(try decoder.decode(GeographicBounds.self, from: data) == tall)
    }

    @Test("Bounds enclose the positions they were built from")
    func boundsEnclose() throws {
        let bounds = try #require(GeographicBounds(enclosing: Self.square))
        #expect(bounds.west == 0 && bounds.south == 0 && bounds.east == 1 && bounds.north == 1)
        #expect(bounds.contains(Coordinate(latitude: 0.5, longitude: 0.5)))
        #expect(bounds.contains(Coordinate(latitude: 0, longitude: 0)))
        #expect(!bounds.contains(Coordinate(latitude: 0.5, longitude: 1.5)))
        #expect(bounds.center == Coordinate(latitude: 0.5, longitude: 0.5))
    }

    @Test("A box across the antimeridian contains the places either side of it")
    func antimeridianContainment() {
        // The trap this exists for: written as `west <= lon && lon <= east` every one of these
        // reads as outside, because west (170) is greater than east (-170).
        let bounds = GeographicBounds(west: 170, south: -20, east: -170, north: -10)
        #expect(bounds.crossesAntimeridian)
        #expect(bounds.contains(Coordinate(latitude: -15, longitude: 175)))
        #expect(bounds.contains(Coordinate(latitude: -15, longitude: -175)))
        #expect(bounds.contains(Coordinate(latitude: -15, longitude: 180)))
        #expect(!bounds.contains(Coordinate(latitude: -15, longitude: 0)))
        #expect(abs(bounds.center.longitude - 180) < 1e-9)
    }

    @Test("Overlap and enclosure survive the wrap")
    func antimeridianOverlap() {
        let wrapped = GeographicBounds(west: 170, south: -20, east: -170, north: -10)
        let east = GeographicBounds(west: 175, south: -18, east: 179, north: -12)
        let elsewhere = GeographicBounds(west: 0, south: -18, east: 10, north: -12)

        #expect(wrapped.intersects(east))
        #expect(wrapped.contains(east))
        #expect(!wrapped.intersects(elsewhere))
        #expect(!wrapped.contains(elsewhere))
    }

    // MARK: - Fixtures

    /// A degree square at the origin, wound counterclockwise.
    static let square = [
        Coordinate(latitude: 0, longitude: 0),
        Coordinate(latitude: 0, longitude: 1),
        Coordinate(latitude: 1, longitude: 1),
        Coordinate(latitude: 1, longitude: 0),
    ]
}
