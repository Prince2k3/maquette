import Foundation
import Testing
import simd
@testable import Maquette

@Suite("Terrain Height Field Tests")
struct TerrainHeightFieldTests {
    private func uniformGrid(_ value: Float, size: Int = 4) -> ElevationGrid {
        ElevationGrid(width: size, height: size, values: [Float](repeating: value, count: size * size))
    }

    @Test("Lowest elevation maps to Y = 0")
    func baselineAtZero() {
        var values = [Float]()
        for row in 0..<4 {
            for col in 0..<4 {
                values.append(Float(100 + row * 10 + col))
            }
        }
        let field = TerrainHeightField(
            grids: [ElevationGrid(width: 4, height: 4, values: values)],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(1, 1),
            elevationScale: 0.01
        )

        #expect(field.minElevation == 100)
        // The corner holding the minimum sits at Y = 0.
        #expect(abs(field.surfaceY(atX: -0.5, z: -0.5)) < 0.0001)
        // Everything else is above it.
        #expect(field.surfaceY(atX: 0.5, z: 0.5) > 0)
    }

    @Test("Elevation scale converts raw meters to diorama meters")
    func elevationScaling() {
        let field = TerrainHeightField(
            grids: [ElevationGrid(width: 2, height: 2, values: [0, 0, 0, 100])],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(1, 1),
            elevationScale: 0.002
        )

        // The 100 m sample sits at the +X/+Z corner.
        #expect(abs(field.surfaceY(atX: 0.5, z: 0.5) - 0.2) < 0.0001)
        #expect(abs(field.maxSurfaceY - 0.2) < 0.0001)
    }

    @Test("Zero scale flattens the surface")
    func zeroScaleFlattens() {
        let field = TerrainHeightField(
            grids: [ElevationGrid(width: 2, height: 2, values: [0, 500, 1000, 1500])],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(1, 1),
            elevationScale: 0
        )

        #expect(field.surfaceY(atX: 0.5, z: 0.5) == 0)
        #expect(field.maxSurfaceY == 0)
    }

    @Test("Bilinear interpolation is smooth between samples")
    func bilinearInterpolation() {
        // A ramp from 0 at -X to 100 at +X.
        let field = TerrainHeightField(
            grids: [ElevationGrid(width: 2, height: 2, values: [0, 100, 0, 100])],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(1, 1),
            elevationScale: 0.001
        )

        #expect(abs(field.rawElevation(atX: -0.5, z: 0) - 0) < 0.01)
        #expect(abs(field.rawElevation(atX: 0, z: 0) - 50) < 0.01)
        #expect(abs(field.rawElevation(atX: 0.25, z: 0) - 75) < 0.01)
        #expect(abs(field.rawElevation(atX: 0.5, z: 0) - 100) < 0.01)
    }

    @Test("Sampling reads the correct tile in a mosaic")
    func multiTileMosaic() {
        // Two tiles side by side: the west tile is low, the east tile is high.
        let field = TerrainHeightField(
            grids: [uniformGrid(200), uniformGrid(800)],
            tilePositions: [(x: 5, y: 3), (x: 6, y: 3)],
            extent: SIMD2(1, 1),
            elevationScale: 0.001
        )

        #expect(abs(field.rawElevation(atX: -0.25, z: 0) - 200) < 0.01, "West half reads the west tile")
        #expect(abs(field.rawElevation(atX: 0.25, z: 0) - 800) < 0.01, "East half reads the east tile")
        #expect(field.minElevation == 200)
        #expect(field.maxElevation == 800)
    }

    @Test("Sampling outside the extent clamps to the edge")
    func clampsOutsideExtent() {
        let field = TerrainHeightField(
            grids: [ElevationGrid(width: 2, height: 2, values: [10, 20, 30, 40])],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(1, 1),
            elevationScale: 0.001
        )

        #expect(field.rawElevation(atX: -50, z: -50) == field.rawElevation(atX: -0.5, z: -0.5))
        #expect(field.rawElevation(atX: 50, z: 50) == field.rawElevation(atX: 0.5, z: 0.5))
    }

    @Test("Explicit baseline overrides the grid minimum")
    func explicitBaseline() {
        let field = TerrainHeightField(
            grids: [uniformGrid(500)],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(1, 1),
            elevationScale: 0.001,
            baselineElevation: 0
        )

        // Sea level is the baseline, so 500 m of terrain sits above Y = 0.
        #expect(abs(field.surfaceY(atX: 0, z: 0) - 0.5) < 0.0001)
    }

    @Test("Non-square extents map each axis independently")
    func nonSquareExtent() {
        let field = TerrainHeightField(
            grids: [ElevationGrid(width: 2, height: 2, values: [0, 100, 0, 100])],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(2.0, 0.5),
            elevationScale: 0.001
        )

        #expect(abs(field.rawElevation(atX: -1.0, z: -0.25) - 0) < 0.01)
        #expect(abs(field.rawElevation(atX: 1.0, z: 0.25) - 100) < 0.01)
        #expect(abs(field.rawElevation(atX: 0, z: 0) - 50) < 0.01)
    }
}
