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

@Suite("Concave Boundary Clipping Tests")
struct ConcaveBoundaryClippingTests {
    /// An L shape covering three quadrants of a unit square, with a reflex vertex at the origin.
    private var lShape: DioramaBoundary {
        DioramaBoundary(vertices: [
            SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(0.5, 0),
            SIMD2(0, 0), SIMD2(0, 0.5), SIMD2(-0.5, 0.5),
        ])
    }

    /// Cell corners wound to match `DioramaBoundary`'s convention.
    private func cell(from lo: SIMD2<Float>, to hi: SIMD2<Float>) -> [(SIMD2<Float>, SIMD2<Float>)] {
        let corners = [
            SIMD2(lo.x, lo.y), SIMD2(lo.x, hi.y), SIMD2(hi.x, hi.y), SIMD2(hi.x, lo.y),
        ]
        return (0..<4).map { (corners[$0], corners[($0 + 1) % 4]) }
    }

    @Test("A cell straddling a reflex vertex keeps the full interior")
    func reflexVertexKeepsInterior() {
        // This cell surrounds the L's reflex corner, so three of its four quadrants are inside.
        // Intersecting the two boundary edges' half-planes would discard one of those quadrants,
        // which is what punched a notch into the surface at every concave corner.
        let clipped = PolygonClipping.clip(
            polygon: lShape.vertices,
            against: cell(from: SIMD2(-0.05, -0.05), to: SIMD2(0.05, 0.05))
        )

        let area = PolygonClipping.area(clipped)
        #expect(abs(area - 0.0075) < 0.0001,
                "Expected three quarters of the cell (0.0075), got \(area)")
    }

    @Test("A cell fully inside a concave boundary is untouched")
    func interiorCellSurvivesIntact() {
        let clipped = PolygonClipping.clip(
            polygon: lShape.vertices,
            against: cell(from: SIMD2(-0.4, -0.4), to: SIMD2(-0.3, -0.3))
        )
        #expect(abs(PolygonClipping.area(clipped) - 0.01) < 0.0001)
    }

    @Test("A cell in the concave notch is discarded")
    func notchCellIsEmpty() {
        let clipped = PolygonClipping.clip(
            polygon: lShape.vertices,
            against: cell(from: SIMD2(0.2, 0.2), to: SIMD2(0.3, 0.3))
        )
        #expect(PolygonClipping.area(clipped) < 0.00001)
    }

    @Test("Ear clipping covers a concave polygon exactly")
    func triangulationCoversConcavePolygon() {
        let polygon = lShape.vertices
        let triangles = PolygonClipping.triangulate(polygon, minimumArea: 0)

        #expect(triangles.count == polygon.count - 2)

        // A fan from one vertex would span the notch and overshoot the true area.
        var total: Float = 0
        for triangle in triangles {
            let a = polygon[triangle.0]
            let b = polygon[triangle.1]
            let c = polygon[triangle.2]
            let ab = b - a
            let ac = c - a
            total += abs(ab.x * ac.y - ab.y * ac.x) / 2
        }
        #expect(abs(total - 0.75) < 0.0001, "Triangles should cover the L's 0.75 area, got \(total)")
    }

    @Test("Ear clipping preserves winding")
    func triangulationPreservesWinding() {
        let polygon = lShape.vertices
        for triangle in PolygonClipping.triangulate(polygon, minimumArea: 0) {
            let a = SIMD3(polygon[triangle.0].x, 0, polygon[triangle.0].y)
            let b = SIMD3(polygon[triangle.1].x, 0, polygon[triangle.1].y)
            let c = SIMD3(polygon[triangle.2].x, 0, polygon[triangle.2].y)
            #expect(simd_cross(b - a, c - a).y > 0, "Triangle faces down")
        }
    }

    @Test("A star chunk covers its true area")
    func starChunkArea() {
        // A five-pointed star, the shape that surfaced the reflex-vertex notches on screen.
        let outerRadius: Float = 0.45
        let innerRadius: Float = 0.19
        let points: [SIMD2<Float>] = (0..<10).map { index in
            let radius = index.isMultiple(of: 2) ? outerRadius : innerRadius
            let angle = Float(index) / 10 * 2 * .pi - .pi / 2
            return SIMD2(radius * cos(angle), radius * sin(angle))
        }

        let heightField = TerrainHeightField(
            grids: [ElevationGrid(width: 8, height: 8, values: [Float](repeating: 300, count: 64))],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(1, 1),
            elevationScale: 0.001
        )

        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: heightField,
            boundary: DioramaBoundary(vertices: points),
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 160
        )

        var area: Float = 0
        for i in stride(from: 0, to: geometry.top.indices.count, by: 3) {
            let a = geometry.top.positions[Int(geometry.top.indices[i])]
            let b = geometry.top.positions[Int(geometry.top.indices[i + 1])]
            let c = geometry.top.positions[Int(geometry.top.indices[i + 2])]
            let ab = SIMD2(b.x - a.x, b.z - a.z)
            let ac = SIMD2(c.x - a.x, c.z - a.z)
            area += abs(ab.x * ac.y - ab.y * ac.x) / 2
        }

        // Ten triangles from the center, each spanning 36 degrees.
        let expected = 5 * outerRadius * innerRadius * sin(Float.pi / 5)
        #expect(abs(area - expected) / expected < 0.01,
                "Star surface area \(area) should match the analytic \(expected)")
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
