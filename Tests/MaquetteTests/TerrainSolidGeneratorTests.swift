import Foundation
import Testing
import simd
@testable import Maquette

@Suite("Terrain Solid Generator Tests")
struct TerrainSolidGeneratorTests {
    // MARK: - Fixtures

    /// A single-tile height field with a cone rising toward the center.
    private func coneHeightField(
        resolution: Int = 32,
        extent: Float = 1.0,
        elevationScale: Float = 0.001
    ) -> TerrainHeightField {
        var values: [Float] = []
        for row in 0..<resolution {
            for col in 0..<resolution {
                let dx = Float(col) / Float(resolution - 1) - 0.5
                let dz = Float(row) / Float(resolution - 1) - 0.5
                let distance = sqrt(dx * dx + dz * dz)
                values.append(100 + max(0, 1 - distance * 2) * 200)
            }
        }
        return TerrainHeightField(
            grids: [ElevationGrid(width: resolution, height: resolution, values: values)],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(extent, extent),
            elevationScale: elevationScale
        )
    }

    private func flatHeightField(extent: Float = 1.0) -> TerrainHeightField {
        TerrainHeightField(
            grids: [ElevationGrid(width: 8, height: 8, values: [Float](repeating: 250, count: 64))],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(extent, extent),
            elevationScale: 0.001
        )
    }

    /// Sum of the triangles' areas projected onto the horizontal plane.
    private func projectedArea(_ buffers: TerrainSolidGenerator.Buffers) -> Float {
        var total: Float = 0
        for i in stride(from: 0, to: buffers.indices.count, by: 3) {
            let a = buffers.positions[Int(buffers.indices[i])]
            let b = buffers.positions[Int(buffers.indices[i + 1])]
            let c = buffers.positions[Int(buffers.indices[i + 2])]
            let ab = SIMD2(b.x - a.x, b.z - a.z)
            let ac = SIMD2(c.x - a.x, c.z - a.z)
            total += abs(ab.x * ac.y - ab.y * ac.x) / 2
        }
        return total
    }

    // MARK: - Boundary Conformance

    @Test("Clipped surface covers the boundary area")
    func surfaceAreaMatchesBoundary() {
        let boundary = DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0))
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: boundary,
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 96
        )

        // A circle of radius 0.5. Exact clipping should land within a fraction of a percent;
        // vertex projection of the kind the old generator used could not.
        let expected = Float.pi * 0.25
        let actual = projectedArea(geometry.top)
        #expect(abs(actual - expected) / expected < 0.01,
                "Surface area \(actual) should match the circle's \(expected)")
    }

    @Test("No surface vertex escapes the boundary")
    func surfaceStaysInsideBoundary() {
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0)),
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 64
        )

        for position in geometry.top.positions {
            let distance = sqrt(position.x * position.x + position.z * position.z)
            #expect(distance <= 0.5 + 0.0005,
                    "Vertex at (\(position.x), \(position.z)) escaped the clip radius")
        }
    }

    @Test("Hexagonal boundary produces a hexagonal footprint")
    func hexagonalFootprint() {
        let boundary = DioramaBoundary.make(shape: .hexagonal, extent: SIMD2(1.0, 1.0))
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: boundary,
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 96
        )

        // A regular hexagon inscribed in a circle of radius r has area 3√3/2 · r².
        let expected = 3 * sqrt(Float(3)) / 2 * 0.25
        let actual = projectedArea(geometry.top)
        #expect(abs(actual - expected) / expected < 0.02)

        for position in geometry.top.positions {
            #expect(boundary.contains(SIMD2(position.x, position.z))
                    || boundary.distance(from: SIMD2(position.x, position.z), toEdge: 0) >= 0)
        }
    }

    // MARK: - Solid Structure

    @Test("Walls span from the base depth up to the terrain surface")
    func wallsSpanFullHeight() {
        let heightField = coneHeightField()
        let baseDepth: Float = 0.12
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: heightField,
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0)),
            baseDepth: baseDepth,
            includesWalls: true,
            includesBottom: true,
            resolution: 64
        )

        #expect(!geometry.walls.positions.isEmpty, "A chunk with depth must have walls")

        for position in geometry.walls.positions {
            let isOnBottom = abs(position.y + baseDepth) < 0.0001
            let expectedSurfaceY = heightField.surfaceY(atX: position.x, z: position.z)
            let isOnSurface = abs(position.y - expectedSurfaceY) < 0.0005

            #expect(isOnBottom || isOnSurface,
                    "Wall vertex at y=\(position.y) sits neither on the base nor on the surface")
        }
    }

    @Test("Wall normals are horizontal and point outward")
    func wallNormalsPointOutward() {
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0)),
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 48
        )

        for (index, normal) in geometry.walls.normals.enumerated() {
            #expect(abs(normal.y) < 0.0001, "Wall normals must stay horizontal")

            // On a circular chunk, outward is the radial direction.
            let position = geometry.walls.positions[index]
            let radial = simd_normalize(SIMD3(position.x, 0, position.z))
            #expect(simd_dot(normal, radial) > 0.9, "Wall normal should face away from the center")
        }
    }

    @Test("Bottom sits at the base depth and faces down")
    func bottomFaceOrientation() {
        let baseDepth: Float = 0.15
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0)),
            baseDepth: baseDepth,
            includesWalls: true,
            includesBottom: true,
            resolution: 48
        )

        #expect(!geometry.bottom.positions.isEmpty)
        for position in geometry.bottom.positions {
            #expect(abs(position.y + baseDepth) < 0.0001)
        }
        for normal in geometry.bottom.normals {
            #expect(normal.y < -0.99, "Bottom face must look down")
        }
    }

    @Test("Top and bottom cover the same footprint")
    func topAndBottomAgree() {
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0)),
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 64
        )

        let topArea = projectedArea(geometry.top)
        let bottomArea = projectedArea(geometry.bottom)
        #expect(abs(topArea - bottomArea) / topArea < 0.001,
                "A closed solid needs matching top and bottom footprints")
    }

    @Test("Surface normals face upward")
    func surfaceNormalsFaceUp() {
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0)),
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 48
        )

        for normal in geometry.top.normals {
            #expect(normal.y > 0, "Terrain surface normals must have an upward component")
            #expect(abs(simd_length(normal) - 1) < 0.001, "Normals must be unit length")
        }
    }

    @Test("Triangle winding makes the surface face up")
    func surfaceWindingFacesUp() {
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: flatHeightField(),
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0)),
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 32
        )

        for i in stride(from: 0, to: geometry.top.indices.count, by: 3) {
            let a = geometry.top.positions[Int(geometry.top.indices[i])]
            let b = geometry.top.positions[Int(geometry.top.indices[i + 1])]
            let c = geometry.top.positions[Int(geometry.top.indices[i + 2])]
            #expect(simd_cross(b - a, c - a).y > 0, "Surface triangle is wound face-down")
        }
    }

    @Test("Bottom winding makes the underside face down")
    func bottomWindingFacesDown() {
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: flatHeightField(),
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0)),
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 32
        )

        for i in stride(from: 0, to: geometry.bottom.indices.count, by: 3) {
            let a = geometry.bottom.positions[Int(geometry.bottom.indices[i])]
            let b = geometry.bottom.positions[Int(geometry.bottom.indices[i + 1])]
            let c = geometry.bottom.positions[Int(geometry.bottom.indices[i + 2])]
            #expect(simd_cross(b - a, c - a).y < 0, "Bottom triangle is wound face-up")
        }
    }

    // MARK: - Configuration

    @Test("Surface-only chunks generate no walls or bottom")
    func surfaceOnlyChunk() {
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0)),
            baseDepth: 0,
            includesWalls: false,
            includesBottom: false,
            resolution: 32
        )

        #expect(!geometry.top.positions.isEmpty)
        #expect(geometry.walls.indices.isEmpty)
        #expect(geometry.bottom.indices.isEmpty)
    }

    @Test("Flat terrain still produces a solid block")
    func flatTerrainStillHasDepth() {
        let baseDepth: Float = 0.2
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: flatHeightField(),
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0)),
            baseDepth: baseDepth,
            includesWalls: true,
            includesBottom: true,
            resolution: 32
        )

        for position in geometry.top.positions {
            #expect(abs(position.y) < 0.0001, "Flat terrain sits at Y=0")
        }
        #expect(!geometry.walls.positions.isEmpty, "Flat terrain still needs walls")

        let minWallY = geometry.walls.positions.map(\.y).min() ?? 0
        #expect(abs(minWallY + baseDepth) < 0.0001)
    }

    @Test("All indices reference existing vertices")
    func indicesAreValid() {
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: DioramaBoundary.make(shape: .hexagonal, extent: SIMD2(1.0, 1.0)),
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 48
        )

        for buffers in [geometry.top, geometry.walls, geometry.bottom] {
            #expect(buffers.indices.count % 3 == 0)
            #expect(buffers.normals.count == buffers.positions.count)
            #expect(buffers.uvs.count == buffers.positions.count)
            for index in buffers.indices {
                #expect(Int(index) < buffers.positions.count)
            }
        }
    }

    @Test("Texture coordinates stay within the unit range")
    func textureCoordinatesInRange() {
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0)),
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 48
        )

        for uv in geometry.top.uvs + geometry.bottom.uvs {
            #expect(uv.x >= 0 && uv.x <= 1)
            #expect(uv.y >= 0 && uv.y <= 1)
        }
        // Wall V runs bottom to top of the chunk; U repeats around the perimeter.
        for uv in geometry.walls.uvs {
            #expect(uv.y >= -0.0001 && uv.y <= 1.0001)
        }
    }

    @Test("Rectangular chunks fill their full footprint")
    func rectangularFootprint() {
        let boundary = DioramaBoundary.make(
            shape: .rectangular(width: 0.8, depth: 0.4),
            extent: SIMD2(0.8, 0.4)
        )
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: boundary,
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 64
        )

        let expected: Float = 0.8 * 0.4
        let actual = projectedArea(geometry.top)
        #expect(abs(actual - expected) / expected < 0.005)
    }
}

@Suite("Chunk Base Depth Tests")
struct ChunkBaseDepthTests {
    @Test("Proportional depth scales with the chunk's extent")
    func proportionalDepth() {
        let depth = ChunkBaseDepth.proportional(0.25)
        #expect(depth.resolved(horizontalExtent: 0.8, relief: 0.05) == 0.2)
    }

    @Test("Absolute depth ignores extent and relief")
    func absoluteDepth() {
        let depth = ChunkBaseDepth.absolute(0.15)
        #expect(depth.resolved(horizontalExtent: 2.0, relief: 0.5) == 0.15)
    }

    @Test("Relief-matched depth falls back to the proportional floor on flat terrain")
    func reliefMatchedDepthFloor() {
        let depth = ChunkBaseDepth.matchingRelief(multiple: 0.8, minimumProportion: 0.1)

        // Mountainous: relief dominates.
        #expect(abs(depth.resolved(horizontalExtent: 1.0, relief: 0.5) - 0.4) < 0.0001)
        // Flat: the floor keeps the chunk from collapsing into a sheet.
        #expect(abs(depth.resolved(horizontalExtent: 1.0, relief: 0.001) - 0.1) < 0.0001)
    }

    @Test("Negative depths are clamped away")
    func negativeDepthsClamped() {
        #expect(ChunkBaseDepth.absolute(-1).resolved(horizontalExtent: 1, relief: 1) == 0)
        #expect(ChunkBaseDepth.proportional(-1).resolved(horizontalExtent: 1, relief: 1) == 0)
    }
}
