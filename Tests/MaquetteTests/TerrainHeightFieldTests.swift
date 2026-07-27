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

    // MARK: - Anchored Residency

    /// A tile whose elevation is its own absolute tile coordinate, so a sample says which tile it
    /// landed on and where within it.
    private func identifyingGrid(x: Int, y: Int) -> ElevationGrid {
        var values = [Float]()
        for row in 0..<2 {
            for col in 0..<2 {
                values.append(Float(x * 1_000 + y * 100 + col * 10 + row))
            }
        }
        return ElevationGrid(width: 2, height: 2, values: values)
    }

    private func anchoredField(
        tiles: [(x: Int, y: Int)],
        anchor: TerrainAnchor
    ) -> TerrainHeightField {
        TerrainHeightField(
            grids: tiles.map { identifyingGrid(x: $0.x, y: $0.y) },
            tilePositions: tiles,
            anchor: anchor,
            elevationScale: 1,
            baselineElevation: 0
        )
    }

    /// One diorama meter per tile, with diorama X/Z = 0 at the corner of tile (100, 100).
    private var testAnchor: TerrainAnchor {
        TerrainAnchor(
            zoom: 12,
            originTile: SIMD2(100, 100),
            tilesPerDioramaMeter: SIMD2(1, 1)
        )
    }

    @Test("Loading more tiles does not move the ground")
    func residencyDoesNotShiftTheGround() {
        // The whole point of an anchor. The old mapping stretched whatever was loaded across the
        // extent, so a tile arriving slid the terrain under the chunk — which is exactly what a
        // rolling fetch would do on every step.
        let anchor = testAnchor
        let narrow = anchoredField(
            tiles: [(x: 100, y: 100), (x: 101, y: 100)],
            anchor: anchor
        )
        let wide = anchoredField(
            tiles: (99...102).flatMap { x in (99...101).map { (x: x, y: $0) } },
            anchor: anchor
        )

        for x in stride(from: Float(0.1), through: 1.9, by: 0.2) {
            for z in stride(from: Float(0.1), through: 0.9, by: 0.2) {
                #expect(narrow.rawElevation(atX: x, z: z) == wide.rawElevation(atX: x, z: z))
            }
        }
    }

    @Test("Residency is reported for loaded tiles only")
    func residencyReporting() {
        let field = anchoredField(tiles: [(x: 100, y: 100), (x: 101, y: 100)], anchor: testAnchor)

        #expect(field.isResident(atX: 0.5, z: 0.5))
        #expect(field.isResident(atX: 1.5, z: 0.5))
        // Beyond the loaded tiles in either axis.
        #expect(!field.isResident(atX: 2.5, z: 0.5))
        #expect(!field.isResident(atX: 0.5, z: 1.5))
        #expect(!field.isResident(atX: -0.5, z: 0.5))
    }

    @Test("Sampling past the loaded tiles clamps rather than falling to the baseline")
    func samplingPastResidencyClamps() {
        // While a rolling fetch is in flight the chunk can reach past what has arrived. Clamping
        // to the edge smears; dropping to the baseline would open a cliff.
        let field = anchoredField(tiles: [(x: 100, y: 100), (x: 101, y: 100)], anchor: testAnchor)

        #expect(field.rawElevation(atX: 5.0, z: 0.5) == field.rawElevation(atX: 2.0, z: 0.5))
        #expect(field.rawElevation(atX: -5.0, z: 0.5) == field.rawElevation(atX: 0.0, z: 0.5))
    }

    @Test("A whole-tile anchor shift and an offset of the same size cancel")
    func anchorShiftCancelsOffset() {
        // Panning sheds whole tiles into the anchor so the offset stays small. If the two did not
        // cancel exactly, every shed tile would jump the terrain.
        let anchor = testAnchor
        let tiles = (99...102).flatMap { x in (99...102).map { (x: x, y: $0) } }
        let before = anchoredField(tiles: tiles, anchor: anchor)
        let after = anchoredField(tiles: tiles, anchor: anchor.shifted(byTiles: SIMD2(1, 1)))

        for x in stride(from: Float(0.1), through: 0.9, by: 0.2) {
            for z in stride(from: Float(0.1), through: 0.9, by: 0.2) {
                #expect(before.rawElevation(atX: x + 1, z: z + 1) == after.rawElevation(atX: x, z: z))
            }
        }
    }

    @Test("Texture coordinates follow the same tiles the elevation does")
    func textureCoordinatesFollowResidency() {
        // Imagery is composited over the resident tiles, so its 0...1 space has to track them —
        // otherwise a rolling fetch slides the imagery off the terrain it belongs to.
        //
        // V runs the other way from Z. Rows count southward from the window's northern tile while
        // RealityKit reads a texture from the bottom of the image up, so the north-west corner of
        // the mosaic is (0, 1) and the south-east is (1, 0). This test used to assert the corners
        // straight through, which is what let the imagery ship mirrored north–south.
        let field = anchoredField(
            tiles: (100...101).flatMap { x in (100...101).map { (x: x, y: $0) } },
            anchor: testAnchor
        )

        #expect(simd_distance(field.textureCoordinate(atX: 0, z: 0), SIMD2(0, 1)) < 1e-6)
        #expect(simd_distance(field.textureCoordinate(atX: 2, z: 2), SIMD2(1, 0)) < 1e-6)
        #expect(simd_distance(field.textureCoordinate(atX: 1, z: 1), SIMD2(0.5, 0.5)) < 1e-6)
    }
}
