import Testing
@testable import Maquette

@Suite("Coordinate Tests")
struct CoordinateTests {
    @Test("Initialize from latitude and longitude")
    func initFromLatLon() {
        let coord = Coordinate(latitude: 40.7128, longitude: -74.0060)
        #expect(coord.latitude == 40.7128)
        #expect(coord.longitude == -74.0060)
    }

    @Test("Latitude and longitude radians conversion")
    func radiansConversion() {
        let coord = Coordinate(latitude: 45.0, longitude: 90.0)
        #expect(abs(coord.latitudeRadians - .pi / 4) < 0.0001)
        #expect(abs(coord.longitudeRadians - .pi / 2) < 0.0001)
    }

    @Test("Distance between two coordinates using Haversine")
    func haversineDistance() {
        let nyc = Coordinate(latitude: 40.7128, longitude: -74.0060)
        let la = Coordinate(latitude: 34.0522, longitude: -118.2437)
        let distance = nyc.distance(to: la)
        // NYC to LA is approximately 3,944 km
        #expect(distance > 3_900_000 && distance < 4_000_000)
    }

    @Test("Distance to self is zero")
    func distanceToSelf() {
        let coord = Coordinate(latitude: 51.5074, longitude: -0.1278)
        let distance = coord.distance(to: coord)
        #expect(distance < 0.01)
    }

    @Test("Offset by meters returns reasonable coordinates")
    func offsetByMeters() {
        let coord = Coordinate(latitude: 0.0, longitude: 0.0)
        let offset = coord.offset(northMeters: 111_320, eastMeters: 0)
        // ~1 degree of latitude ≈ 111,320 meters
        #expect(abs(offset.latitude - 1.0) < 0.01)
        #expect(abs(offset.longitude) < 0.01)
    }

    @Test("Round-trip distance via offset")
    func roundTripOffset() {
        let origin = Coordinate(latitude: 48.8566, longitude: 2.3522) // Paris
        let offset = origin.offset(northMeters: 1000, eastMeters: 1000)
        let distance = origin.distance(to: offset)
        // Should be approximately sqrt(2) * 1000 ≈ 1414 meters
        #expect(distance > 1400 && distance < 1430)
    }

    @Test("Description format")
    func descriptionFormat() {
        let coord = Coordinate(latitude: 40.712800, longitude: -74.006000)
        let desc = coord.description
        #expect(desc.contains("40.712800"))
        #expect(desc.contains("-74.006000"))
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
}
