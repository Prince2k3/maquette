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

    /// Terrain far above the ellipsoid must survive culling.
    ///
    /// The local origin sits at ellipsoid height zero, so a volume high in the mountains is a long
    /// way from it vertically while being directly overhead. Culling on 3D distance therefore
    /// throws away exactly the tiles the chunk is made of — and only in terrain with relief, since
    /// at sea level the vertical term is nil and the wrong test looks right. Half Dome is the
    /// case that exposed it: a 1,400 m chunk around a summit ~2,700 m up rendered black.
    @Test("A volume high above the ellipsoid is not culled by its height")
    func highAltitudeVolumeSurvivesCulling() {
        let center = CLLocationCoordinate2D(latitude: 37.7459, longitude: -119.5332)
        let summit: Float = 2_700
        let radiusMeters: Double = 1_400

        // Horizontally centred, but far higher than the chunk is wide.
        let sphere = BoundingVolume.sphere(center: SIMD3<Float>(0, summit, 0), radius: 50)
        #expect(sphere.intersects(center: center, radiusMeters: radiusMeters))

        let box = BoundingVolume.box(
            center: SIMD3<Float>(0, summit, 0),
            halfAxes: simd_float3x3(SIMD3<Float>(50, 0, 0), SIMD3<Float>(0, 50, 0), SIMD3<Float>(0, 0, 50))
        )
        #expect(box.intersects(center: center, radiusMeters: radiusMeters))
    }

    /// Height is ignored, but horizontal distance still culls.
    @Test("A volume outside the footprint is still culled whatever its height")
    func distantVolumeIsCulled() {
        let center = CLLocationCoordinate2D(latitude: 37.7459, longitude: -119.5332)
        let radiusMeters: Double = 1_400

        // Well beyond the radius to the east, at the same height as the origin.
        let sphere = BoundingVolume.sphere(center: SIMD3<Float>(5_000, 0, 0), radius: 50)
        #expect(!sphere.intersects(center: center, radiusMeters: radiusMeters))

        let box = BoundingVolume.box(
            center: SIMD3<Float>(0, 0, 5_000),
            halfAxes: simd_float3x3(SIMD3<Float>(50, 0, 0), SIMD3<Float>(0, 50, 0), SIMD3<Float>(0, 0, 50))
        )
        #expect(!box.intersects(center: center, radiusMeters: radiusMeters))
    }

    /// The far side of the planet is directly below the origin, and must not be mistaken for it.
    ///
    /// Letting the column run without a floor made it pass through the Earth: at the antipode the
    /// east and north components are both nil, so the horizontal distance from the origin is zero
    /// and the tiles there read as dead centre. Google's tileset is rooted at the whole planet, so
    /// it has some, and they arrived as geometry an Earth diameter below the table — which then
    /// became the lowest thing loaded and dragged the tray and the vertical datum down with it.
    @Test("Geometry on the far side of the Earth is culled despite being directly below")
    func antipodalVolumeIsCulled() {
        let center = CLLocationCoordinate2D(latitude: 37.7459, longitude: -119.5332)
        let radiusMeters: Double = 1_400
        let earthDiameter: Float = 12_738_000

        let sphere = BoundingVolume.sphere(center: SIMD3<Float>(0, -earthDiameter, 0), radius: 500)
        #expect(!sphere.intersects(center: center, radiusMeters: radiusMeters))

        let box = BoundingVolume.box(
            center: SIMD3<Float>(0, -earthDiameter, 0),
            halfAxes: simd_float3x3(SIMD3<Float>(500, 0, 0), SIMD3<Float>(0, 500, 0), SIMD3<Float>(0, 0, 500))
        )
        #expect(!box.intersects(center: center, radiusMeters: radiusMeters))

        // The Earth's centre is the same mistake at half the depth, and must go too.
        let core = BoundingVolume.sphere(center: SIMD3<Float>(0, -earthDiameter / 2, 0), radius: 500)
        #expect(!core.intersects(center: center, radiusMeters: radiusMeters))
    }
}
