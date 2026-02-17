import CoreLocation
import Foundation
import Testing
import simd
@testable import Maquette

@Suite("ECEF Converter Tests")
struct ECEFConverterTests {

    @Test("Origin converts to near-zero local coordinates")
    func originConvertsToZero() {
        let origin = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let converter = ECEFConverter(origin: origin)

        let local = converter.ecefToLocal(converter.originECEF)
        #expect(abs(local.x) < 0.01)
        #expect(abs(local.y) < 0.01)
        #expect(abs(local.z) < 0.01)
    }

    @Test("ECEF origin is computed correctly for equator-prime-meridian")
    func ecefAtEquatorPrimeMeridian() {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let converter = ECEFConverter(origin: origin)

        // At equator, prime meridian, altitude 0: X ≈ 6378137, Y ≈ 0, Z ≈ 0
        #expect(abs(converter.originECEF.x - 6_378_137.0) < 1.0)
        #expect(abs(converter.originECEF.y) < 1.0)
        #expect(abs(converter.originECEF.z) < 1.0)
    }

    @Test("Point east of origin has positive X")
    func eastPointHasPositiveX() {
        let origin = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let converter = ECEFConverter(origin: origin)

        // A point slightly east (more positive longitude)
        let eastCoord = CLLocationCoordinate2D(latitude: 40.7128, longitude: -73.9960)
        let eastLatRad = eastCoord.latitude * .pi / 180.0
        let eastLonRad = eastCoord.longitude * .pi / 180.0
        let sinLat = sin(eastLatRad)
        let cosLat = cos(eastLatRad)
        let sinLon = sin(eastLonRad)
        let cosLon = cos(eastLonRad)
        let n = 6_378_137.0 / sqrt(1.0 - 0.00669437999014 * sinLat * sinLat)
        let eastECEF = SIMD3<Double>(
            n * cosLat * cosLon,
            n * cosLat * sinLon,
            n * (1.0 - 0.00669437999014) * sinLat
        )

        let local = converter.ecefToLocal(eastECEF)
        // East = positive X in RealityKit
        #expect(local.x > 0)
    }

    @Test("Point north of origin has negative Z (RealityKit convention)")
    func northPointHasNegativeZ() {
        let origin = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        let converter = ECEFConverter(origin: origin)

        // A point slightly north
        let northCoord = CLLocationCoordinate2D(latitude: 40.7228, longitude: -74.0060)
        let latRad = northCoord.latitude * .pi / 180.0
        let lonRad = northCoord.longitude * .pi / 180.0
        let sinLat = sin(latRad)
        let cosLat = cos(latRad)
        let sinLon = sin(lonRad)
        let cosLon = cos(lonRad)
        let n = 6_378_137.0 / sqrt(1.0 - 0.00669437999014 * sinLat * sinLat)
        let northECEF = SIMD3<Double>(
            n * cosLat * cosLon,
            n * cosLat * sinLon,
            n * (1.0 - 0.00669437999014) * sinLat
        )

        let local = converter.ecefToLocal(northECEF)
        // North = -Z in RealityKit (since we map ENU → (X, Up, -North))
        #expect(local.z < 0)
    }

    @Test("Transform preserves translation component")
    func transformPreservesTranslation() {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let converter = ECEFConverter(origin: origin)

        let identity = simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
        var transform = identity
        transform.columns.3 = SIMD4<Float>(
            Float(converter.originECEF.x),
            Float(converter.originECEF.y),
            Float(converter.originECEF.z),
            1
        )

        let local = converter.ecefTransformToLocal(transform)
        // Translation should be near zero since it's at the origin
        #expect(abs(local.columns.3.x) < 1.0)
        #expect(abs(local.columns.3.y) < 1.0)
        #expect(abs(local.columns.3.z) < 1.0)
    }
}
