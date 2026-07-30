import Foundation
import Testing
@testable import Maquette

@Suite("Coordinate Tests")
struct CoordinateTests {
    @Test("Initialize from latitude and longitude")
    func initFromLatLon() {
        let coord = Coordinate(latitude: 40.7128, longitude: -74.0060)
        #expect(coord.latitude == 40.7128)
        #expect(coord.longitude == -74.0060)
        #expect(coord.altitude == nil)
    }

    @Test("Both argument orders name the same place")
    func bothArgumentOrders() {
        #expect(
            Coordinate(latitude: 40.7128, longitude: -74.0060)
                == Coordinate(longitude: -74.0060, latitude: 40.7128)
        )
    }

    @Test("Latitude and longitude radians conversion")
    func radiansConversion() {
        let coord = Coordinate(latitude: 45.0, longitude: 90.0)
        #expect(abs(coord.latitudeRadians - .pi / 4) < 0.0001)
        #expect(abs(coord.longitudeRadians - .pi / 2) < 0.0001)
    }

    @Test("Description names which number is which")
    func descriptionFormat() {
        let coord = Coordinate(latitude: 40.712800, longitude: -74.006000)
        #expect(coord.description.contains("lat: 40.712800"))
        #expect(coord.description.contains("lon: -74.006000"))
    }

    @Test("Hashable conformance")
    func hashable() {
        let a = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let b = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let c = Coordinate(latitude: 0.0, longitude: 0.0)
        #expect(a == b)
        #expect(a != c)

        let set: Set<Coordinate> = [a, b, c]
        #expect(set.count == 2)
    }

    @Test("An altitude is part of the position, not decoration")
    func altitudeIsPartOfTheValue() {
        let flat = Coordinate(latitude: 1, longitude: 2)
        let grounded = Coordinate(latitude: 1, longitude: 2, altitude: 0)
        #expect(flat != grounded)
        #expect(flat.at(altitude: 0) == grounded)
        #expect(grounded.horizontal == flat)
    }

    // MARK: - GeoJSON representation

    @Test("Encodes as a GeoJSON position, longitude first")
    func encodesLongitudeFirst() throws {
        let json = try JSONEncoder().encode(Coordinate(latitude: 40.7128, longitude: -74.0060))
        let values = try JSONDecoder().decode([Double].self, from: json)
        #expect(values == [-74.0060, 40.7128])
    }

    @Test("Decodes a two-element position in longitude/latitude order")
    func decodesLongitudeFirst() throws {
        let coordinate = try JSONDecoder().decode(
            Coordinate.self,
            from: Data("[-74.0060, 40.7128]".utf8)
        )
        #expect(coordinate.longitude == -74.0060)
        #expect(coordinate.latitude == 40.7128)
        #expect(coordinate.altitude == nil)
    }

    @Test("A third element is an altitude and survives the round trip")
    func altitudeRoundTrip() throws {
        let original = Coordinate(latitude: 46.85, longitude: -121.76, altitude: 4392)
        let decoded = try JSONDecoder().decode(
            Coordinate.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    @Test("Positions longer than three elements keep their first three")
    func extraElementsIgnored() throws {
        let coordinate = try JSONDecoder().decode(
            Coordinate.self,
            from: Data("[1, 2, 3, 4, 5]".utf8)
        )
        #expect(coordinate == Coordinate(longitude: 1, latitude: 2, altitude: 3))
    }

    @Test("A position of fewer than two elements is rejected")
    func shortPositionRejected() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Coordinate.self, from: Data("[1]".utf8))
        }
    }
}
