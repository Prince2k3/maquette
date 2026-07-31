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
