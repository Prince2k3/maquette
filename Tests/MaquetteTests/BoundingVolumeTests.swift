import CoreLocation
import Foundation
import Testing
import simd
@testable import Maquette

@Suite("Bounding Volume Tests")
struct BoundingVolumeTests {

    @Test("Region bounding volume from JSON")
    func regionFromJSON() {
        let json = BoundingVolumeJSON(
            region: [-1.3197, 0.6988, -1.3196, 0.6989, 0, 88],
            box: nil,
            sphere: nil
        )
        let bv = BoundingVolume(from: json)
        #expect(bv != nil)
        if case .region(let west, let south, let east, let north, let minH, let maxH) = bv {
            #expect(west == -1.3197)
            #expect(south == 0.6988)
            #expect(east == -1.3196)
            #expect(north == 0.6989)
            #expect(minH == 0)
            #expect(maxH == 88)
        }
    }

    @Test("Sphere bounding volume from JSON")
    func sphereFromJSON() {
        let json = BoundingVolumeJSON(
            region: nil,
            box: nil,
            sphere: [100.0, 200.0, 300.0, 50.0]
        )
        let bv = BoundingVolume(from: json)
        #expect(bv != nil)
        if case .sphere(let center, let radius) = bv {
            #expect(center.x == 100.0)
            #expect(center.y == 200.0)
            #expect(center.z == 300.0)
            #expect(radius == 50.0)
        }
    }

    @Test("Box bounding volume from JSON")
    func boxFromJSON() {
        let json = BoundingVolumeJSON(
            region: nil,
            box: [0, 0, 0, 10, 0, 0, 0, 10, 0, 0, 0, 10],
            sphere: nil
        )
        let bv = BoundingVolume(from: json)
        #expect(bv != nil)
        if case .box(let center, let halfAxes) = bv {
            #expect(center == .zero)
            #expect(halfAxes.columns.0.x == 10.0)
        }
    }

    @Test("Invalid JSON returns nil")
    func invalidJSON() {
        let json = BoundingVolumeJSON(region: nil, box: nil, sphere: nil)
        #expect(BoundingVolume(from: json) == nil)
    }

    @Test("Screen-space error calculation")
    func screenSpaceError() {
        let bv = BoundingVolume.sphere(center: SIMD3<Float>(0, 0, -10), radius: 5)
        let sse = bv.screenSpaceError(
            geometricError: 100.0,
            cameraPosition: .zero,
            screenHeight: 1000,
            fov: Float.pi / 3.0 // 60 degrees
        )
        // SSE = (100 * 1000) / (10 * 2 * tan(pi/6)) ≈ 8660
        #expect(sse > 1000)
    }

    @Test("Region intersection with nearby coordinate")
    func regionIntersectsNearby() {
        // Region around NYC in radians
        let bv = BoundingVolume.region(
            west: -1.295, south: 0.710,
            east: -1.290, north: 0.715,
            minHeight: 0, maxHeight: 500
        )
        let nyc = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        #expect(bv.intersects(center: nyc, radiusMeters: 10000))
    }
}
