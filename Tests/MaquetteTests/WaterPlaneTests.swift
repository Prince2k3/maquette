import Testing
import simd
@testable import Maquette

@Suite("Water plane")
struct WaterPlaneTests {
    /// A square chunk of the given width, centred on the origin.
    private func boundary(width: Float) -> DioramaBoundary {
        let half = width / 2
        return DioramaBoundary(vertices: [
            SIMD2(-half, -half),
            SIMD2(half, -half),
            SIMD2(half, half),
            SIMD2(-half, half)
        ])
    }

    @Test("A coast gets water; open ocean gets none")
    func waterBelongsWhereThereIsLandToMeet() {
        // A coast: seabed below the datum, headland above it. Without the plane the sea is a hole in
        // the chunk with the beach standing over it.
        #expect(WaterPlaneEntity.belongsInRegion(minElevation: -120, maxElevation: 340))
        // Open ocean, as Terrarium reports it — every point flat at the datum. A plane here covers the
        // whole top face, and the chunk comes back as a blue lid over sealed-off terrain.
        #expect(!WaterPlaneEntity.belongsInRegion(minElevation: 0, maxElevation: 0))
        // Deep ocean, where the tiles do carry bathymetry. Still no land, so still no plane — this is
        // the case that used to render as a disc floating clear of the seabed.
        #expect(!WaterPlaneEntity.belongsInRegion(minElevation: -5300, maxElevation: -60))
    }

    @Test("A single rock out of the water is still land")
    func theSmallestLandIsEnough() {
        // Nothing here weighs how *much* land there is. An atoll is mostly lagoon and reads as one,
        // and the alternative — a share of the chunk that has to be above water — is a threshold
        // nobody can name that would delete the water from real coastlines just short of it.
        #expect(WaterPlaneEntity.belongsInRegion(minElevation: -400, maxElevation: 1))
    }

    @Test("Ground wholly above sea level never had a sea-level plane to draw")
    func inlandTerrainIsUnaffected() {
        // An alpine valley, and the lake in it — which this plane has never drawn, since it fills the
        // datum and a lake sits wherever its own surface is. Unchanged by the gate either way.
        #expect(!WaterPlaneEntity.belongsInRegion(minElevation: 1600, maxElevation: 2900))
    }

    @Test("The water surface never lands on a flat seabed")
    func waterClearsAFlatSeabed() {
        // Terrarium reports whole regions of open ocean as exactly 0 m, so the baseline is 0 and
        // every terrain vertex sits at Y = 0. The water must not.
        let y = WaterPlaneEntity.surfaceY(
            boundary: boundary(width: 0.8),
            baselineElevation: 0,
            elevationScale: 0.0001
        )
        #expect(y > 0)
    }

    @Test("The clearance is measured against the chunk, not in absolute metres")
    func clearanceScalesWithTheChunk() {
        let small = WaterPlaneEntity.surfaceY(
            boundary: boundary(width: 0.4),
            baselineElevation: 0,
            elevationScale: 0.0001
        )
        let large = WaterPlaneEntity.surfaceY(
            boundary: boundary(width: 0.8),
            baselineElevation: 0,
            elevationScale: 0.0001
        )
        #expect(large.isApproximatelyEqual(to: small * 2, tolerance: 1e-9))
    }

    @Test("A ground zoom cannot shrink the clearance away")
    func clearanceSurvivesAGroundZoom() {
        // Zooming the map out divides the elevation scale. The lift rides the chunk's footprint
        // instead, which a zoom does not change, so the separation holds.
        let outline = boundary(width: 0.8)
        let near = WaterPlaneEntity.surfaceY(
            boundary: outline,
            baselineElevation: 0,
            elevationScale: 0.0001
        )
        let far = WaterPlaneEntity.surfaceY(
            boundary: outline,
            baselineElevation: 0,
            elevationScale: 0.0001 / 64
        )
        #expect(far.isApproximatelyEqual(to: near, tolerance: 1e-9))
    }

    @Test("Sea level still rides the elevation scale")
    func seaLevelRidesTheElevationScale() {
        // Where the tiles do carry bathymetry the baseline is below sea level, and the water has to
        // sit that much of the elevation scale above the chunk's floor.
        let outline = boundary(width: 0.8)
        let scale: Float = 0.0001
        let floor = WaterPlaneEntity.surfaceY(
            boundary: outline,
            baselineElevation: 0,
            elevationScale: scale
        )
        let deep = WaterPlaneEntity.surfaceY(
            boundary: outline,
            baselineElevation: -5000,
            elevationScale: scale
        )
        #expect((deep - floor).isApproximatelyEqual(to: 5000 * scale, tolerance: 1e-6))
    }

    @Test("The clearance is far below anything the eye resolves")
    func clearanceIsInvisible() {
        // It exists to break a depth-buffer tie, not to float the water. A tenth of a millimetre on
        // a chunk the size of a dinner plate.
        let y = WaterPlaneEntity.surfaceY(
            boundary: boundary(width: 0.8),
            baselineElevation: 0,
            elevationScale: 0.0001
        )
        #expect(y < 0.001)
    }
}

private extension Float {
    func isApproximatelyEqual(to other: Float, tolerance: Float) -> Bool {
        abs(self - other) <= tolerance
    }
}
