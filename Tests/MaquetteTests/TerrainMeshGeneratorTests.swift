import Testing
@testable import Maquette

@Suite("Terrain Mesh Generator Tests")
struct TerrainMeshGeneratorTests {
    @Test("Grid geometry produces correct vertex count")
    func vertexCount() {
        let grid = ElevationGrid(
            width: 16,
            height: 16,
            values: [Float](repeating: 100.0, count: 16 * 16)
        )

        let (positions, normals, uvs, indices) = TerrainMeshGenerator.generateGridGeometry(
            grid: grid,
            resolution: 8,
            size: 1.0,
            geographicScale: 0.001,
            exaggeration: 1.5,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScale: 1.0
        )

        // With resolution 8 and grid width 16, step = 2, cols = 8, rows = 8
        // But actually: step = max(1, 16/8) = 2, cols = (16-1)/2 + 1 = 8, rows = 8
        #expect(positions.count == 8 * 8)
        #expect(normals.count == positions.count)
        #expect(uvs.count == positions.count)

        // Indices: (8-1) * (8-1) * 6 = 294
        #expect(indices.count == 7 * 7 * 6)
    }

    @Test("Flat elevation produces all-upward normals")
    func flatTerrainNormals() {
        let grid = ElevationGrid(
            width: 4,
            height: 4,
            values: [Float](repeating: 0.0, count: 16)
        )

        let (_, normals, _, _) = TerrainMeshGenerator.generateGridGeometry(
            grid: grid,
            resolution: 4,
            size: 1.0,
            geographicScale: 0.001,
            exaggeration: 0,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScale: 1.0
        )

        for normal in normals {
            // With zero exaggeration, normals should be approximately (0, 1, 0)
            #expect(abs(normal.y) > 0.9)
        }
    }

    @Test("UV coordinates are within 0-1 range")
    func uvRange() {
        let grid = ElevationGrid(
            width: 8,
            height: 8,
            values: [Float](repeating: 50.0, count: 64)
        )

        let (_, _, uvs, _) = TerrainMeshGenerator.generateGridGeometry(
            grid: grid,
            resolution: 8,
            size: 1.0,
            geographicScale: 0.001,
            exaggeration: 1.0,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScale: 1.0
        )

        for uv in uvs {
            #expect(uv.x >= 0.0 && uv.x <= 1.0)
            #expect(uv.y >= 0.0 && uv.y <= 1.0)
        }
    }

    @Test("All triangle indices are valid")
    func validIndices() {
        let grid = ElevationGrid(
            width: 16,
            height: 16,
            values: (0..<256).map { Float($0) }
        )

        let (positions, _, _, indices) = TerrainMeshGenerator.generateGridGeometry(
            grid: grid,
            resolution: 8,
            size: 1.0,
            geographicScale: 0.001,
            exaggeration: 1.0,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScale: 1.0
        )

        for index in indices {
            #expect(Int(index) < positions.count)
        }
    }

    @Test("Index count is multiple of 3 (triangles)")
    func triangleIndices() {
        let grid = ElevationGrid(
            width: 8,
            height: 8,
            values: [Float](repeating: 0, count: 64)
        )

        let (_, _, _, indices) = TerrainMeshGenerator.generateGridGeometry(
            grid: grid,
            resolution: 4,
            size: 1.0,
            geographicScale: 0.001,
            exaggeration: 1.0,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScale: 1.0
        )

        #expect(indices.count % 3 == 0)
    }
}
