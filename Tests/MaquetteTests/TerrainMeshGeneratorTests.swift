import Foundation
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
            sizeX: 1.0,
            sizeZ: 1.0,
            geographicScale: 0.001,
            exaggeration: 1.5,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScaleX: 1.0,
            uvScaleY: 1.0,
            clipRadius: nil,
            globalMinElev: nil
        )

        // With resolution 8 and grid width 16, step = 2, cols = 8, rows = 8
        // Surface vertices = 64, plus skirt vertices for rectangular boundary
        let surfaceVertexCount = 8 * 8
        #expect(positions.count >= surfaceVertexCount)
        #expect(normals.count == positions.count)
        #expect(uvs.count == positions.count)

        // Indices should be a multiple of 3 (triangles)
        #expect(indices.count % 3 == 0)
    }

    @Test("Flat elevation produces all-upward normals for surface vertices")
    func flatTerrainNormals() {
        let grid = ElevationGrid(
            width: 4,
            height: 4,
            values: [Float](repeating: 0.0, count: 16)
        )

        let (positions, normals, _, _) = TerrainMeshGenerator.generateGridGeometry(
            grid: grid,
            resolution: 4,
            sizeX: 1.0,
            sizeZ: 1.0,
            geographicScale: 0.001,
            exaggeration: 0,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScaleX: 1.0,
            uvScaleY: 1.0,
            clipRadius: nil,
            globalMinElev: nil
        )

        // Surface vertices are the first 4*4 = 16 vertices
        let surfaceCount = 4 * 4
        for i in 0..<min(surfaceCount, normals.count) {
            // With zero exaggeration all terrain is flat, so normals should point up
            // But skirt walls will have outward normals; only check surface vertices
            if positions[i].y == 0 && i < surfaceCount {
                #expect(abs(normals[i].y) > 0.9)
            }
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
            sizeX: 1.0,
            sizeZ: 1.0,
            geographicScale: 0.001,
            exaggeration: 1.0,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScaleX: 1.0,
            uvScaleY: 1.0,
            clipRadius: nil,
            globalMinElev: nil
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
            sizeX: 1.0,
            sizeZ: 1.0,
            geographicScale: 0.001,
            exaggeration: 1.0,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScaleX: 1.0,
            uvScaleY: 1.0,
            clipRadius: nil,
            globalMinElev: nil
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
            sizeX: 1.0,
            sizeZ: 1.0,
            geographicScale: 0.001,
            exaggeration: 1.0,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScaleX: 1.0,
            uvScaleY: 1.0,
            clipRadius: nil,
            globalMinElev: nil
        )

        #expect(indices.count % 3 == 0)
    }

    // MARK: - New Tests for Terrain Containment Fixes

    @Test("Minimum elevation vertex sits at Y=0")
    func minimumElevationAtYZero() {
        // Create a grid with varying elevations (50 to 200)
        var values = [Float]()
        for row in 0..<8 {
            for col in 0..<8 {
                values.append(Float(50 + row * 10 + col * 5))
            }
        }
        let grid = ElevationGrid(width: 8, height: 8, values: values)

        let (positions, _, _, _) = TerrainMeshGenerator.generateGridGeometry(
            grid: grid,
            resolution: 8,
            sizeX: 1.0,
            sizeZ: 1.0,
            geographicScale: 0.001,
            exaggeration: 1.5,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScaleX: 1.0,
            uvScaleY: 1.0,
            clipRadius: nil,
            globalMinElev: 50.0  // The minimum elevation in the grid
        )

        // The minimum Y position among surface vertices should be 0
        // (since the vertex with elevation 50 maps to (50 - 50) * scale = 0)
        let minY = positions.map(\.y).min() ?? Float.infinity
        #expect(minY >= 0.0, "Minimum Y should be >= 0 (terrain sits on base)")
        #expect(minY < 0.01, "Minimum Y should be very close to 0")
    }

    @Test("Circular clipping keeps vertices within clip radius")
    func circularClippingBounds() {
        let grid = ElevationGrid(
            width: 16,
            height: 16,
            values: [Float](repeating: 100.0, count: 16 * 16)
        )

        let clipRadius: Float = 0.4

        let (positions, _, _, _) = TerrainMeshGenerator.generateGridGeometry(
            grid: grid,
            resolution: 16,
            sizeX: 1.0,
            sizeZ: 1.0,
            geographicScale: 0.001,
            exaggeration: 1.5,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScaleX: 1.0,
            uvScaleY: 1.0,
            clipRadius: clipRadius,
            globalMinElev: 100.0
        )

        // All vertex XZ distances must be within the clip radius (with small tolerance)
        let tolerance: Float = 0.001
        for pos in positions {
            let dist = sqrt(pos.x * pos.x + pos.z * pos.z)
            #expect(dist <= clipRadius + tolerance,
                    "Vertex at (\(pos.x), \(pos.z)) is outside clip radius: dist=\(dist), radius=\(clipRadius)")
        }
    }

    @Test("Skirt vertices present with circular clipping")
    func skirtVerticesWithClipping() {
        // Use a higher-resolution grid with a large elevation range and a clip radius
        // that leaves many interior boundary vertices (within 95% of radius) with y > 0.
        // The center of the grid has the highest elevation so interior vertices near
        // the clip edge have non-zero y values, triggering skirt generation.
        let res = 32
        var values = [Float]()
        for row in 0..<res {
            for col in 0..<res {
                // Peak elevation at center, minimum at corners
                let cx = Float(col) / Float(res - 1) - 0.5
                let cz = Float(row) / Float(res - 1) - 0.5
                let dist = sqrt(cx * cx + cz * cz)
                values.append(500.0 + (1.0 - dist) * 500.0)
            }
        }
        let grid = ElevationGrid(width: res, height: res, values: values)

        let clipRadius: Float = 0.4

        let (positions, _, _, _) = TerrainMeshGenerator.generateGridGeometry(
            grid: grid,
            resolution: res,
            sizeX: 1.0,
            sizeZ: 1.0,
            geographicScale: 0.001,
            exaggeration: 2.0,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScaleX: 1.0,
            uvScaleY: 1.0,
            clipRadius: clipRadius,
            globalMinElev: 500.0
        )

        // With clipping and varying elevations, boundary vertices with y > 0
        // get paired with skirt vertices at y=0, adding extra geometry
        let surfaceCount = res * res
        #expect(positions.count > surfaceCount,
                "Expected skirt vertices to be added beyond the \(surfaceCount) surface vertices")

        // Verify some skirt vertices are at Y=0
        let yZeroCount = positions.filter { abs($0.y) < 0.001 }.count
        #expect(yZeroCount > 0, "Expected some vertices at Y=0 for skirt walls")
    }

    @Test("Rectangular boundary produces skirt vertices")
    func rectangularSkirtVertices() {
        let grid = ElevationGrid(
            width: 8,
            height: 8,
            values: [Float](repeating: 500.0, count: 64)
        )

        let (positions, _, _, _) = TerrainMeshGenerator.generateGridGeometry(
            grid: grid,
            resolution: 8,
            sizeX: 1.0,
            sizeZ: 1.0,
            geographicScale: 0.001,
            exaggeration: 1.0,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScaleX: 1.0,
            uvScaleY: 1.0,
            clipRadius: nil,  // No clipping = rectangular
            globalMinElev: 500.0
        )

        // Rectangular boundary should also have skirt vertices
        let surfaceCount = 8 * 8
        #expect(positions.count > surfaceCount,
                "Expected skirt vertices for rectangular boundary")
    }
}
