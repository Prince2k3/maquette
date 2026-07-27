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

    /// The column has to travel with the outline, or the pan is a bounded region rather than a
    /// gesture.
    ///
    /// The tiles never move; the outline does. A column left at the placement origin therefore
    /// walks towards its own edge as the user drags, and the tiles ahead of the outline are culled
    /// before they are ever requested — so the model simply ends in the direction of travel while
    /// the margin behind it stays fully stocked. That is what bounded the photorealistic pan.
    @Test("The cull column follows the outline rather than the placement origin")
    func offsetMovesTheCullColumn() {
        let center = CLLocationCoordinate2D(latitude: 37.7459, longitude: -119.5332)
        let radiusMeters: Double = 1_400

        // Ground 2 km east: beyond the radius from the origin, well within it once the outline has
        // been dragged 2 km east.
        let ahead = BoundingVolume.sphere(center: SIMD3<Float>(2_000, 0, 0), radius: 50)
        #expect(!ahead.intersects(center: center, radiusMeters: radiusMeters))
        #expect(ahead.intersects(center: center, radiusMeters: radiusMeters, offsetMeters: SIMD2(2_000, 0)))

        // And the same statement from behind: ground at the origin drops out once the outline has
        // left it far enough behind. Culling what is no longer wanted is what keeps the stream from
        // growing without bound as the pan runs on.
        let behind = BoundingVolume.sphere(center: .zero, radius: 50)
        #expect(behind.intersects(center: center, radiusMeters: radiusMeters))
        #expect(!behind.intersects(center: center, radiusMeters: radiusMeters, offsetMeters: SIMD2(2_000, 0)))
    }

    /// The offset's second component is RealityKit's z, which runs south — so a positive value moves
    /// the column towards lower latitudes. Getting the sign backwards culls precisely the tiles the
    /// drag was reaching for, and does it symmetrically enough to look like no movement at all.
    @Test("The column's north-south axis runs the way RealityKit's z does")
    func offsetSignFollowsRealityKitZ() {
        let center = CLLocationCoordinate2D(latitude: 37.7459, longitude: -119.5332)
        let radiusMeters: Double = 1_400

        let south = BoundingVolume.sphere(center: SIMD3<Float>(0, 0, 2_000), radius: 50)
        #expect(!south.intersects(center: center, radiusMeters: radiusMeters))
        #expect(south.intersects(center: center, radiusMeters: radiusMeters, offsetMeters: SIMD2(0, 2_000)))
        #expect(!south.intersects(center: center, radiusMeters: radiusMeters, offsetMeters: SIMD2(0, -2_000)))
    }

    /// Region volumes are geographic, so the column's offset has to be converted before it can be
    /// compared — and the two branches have to agree about which way is which, since a tileset may
    /// mix them.
    @Test("A region volume's cull follows the column too")
    func offsetMovesTheCullColumnForRegions() {
        // A degree is roughly 111 km, so a region a tenth of a degree east is about 11 km out.
        let center = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let radiusMeters: Double = 1_000
        let tenth = 0.1 * .pi / 180.0

        let east = BoundingVolume.region(
            west: tenth * 0.99, south: -tenth * 0.01,
            east: tenth * 1.01, north: tenth * 0.01,
            minHeight: 0, maxHeight: 100
        )
        #expect(!east.intersects(center: center, radiusMeters: radiusMeters))
        #expect(east.intersects(center: center, radiusMeters: radiusMeters, offsetMeters: SIMD2(11_119, 0)))

        // Southward, where the sign is the one that is easy to invert.
        let south = BoundingVolume.region(
            west: -tenth * 0.01, south: -tenth * 1.01,
            east: tenth * 0.01, north: -tenth * 0.99,
            minHeight: 0, maxHeight: 100
        )
        #expect(!south.intersects(center: center, radiusMeters: radiusMeters))
        #expect(south.intersects(center: center, radiusMeters: radiusMeters, offsetMeters: SIMD2(0, 11_119)))
        #expect(!south.intersects(center: center, radiusMeters: radiusMeters, offsetMeters: SIMD2(0, -11_119)))
    }
}
