import simd
import Testing
@testable import Maquette

@Suite("Overlay terrain intersection")
struct OverlaySurfaceGeometryTests {
    @Test(arguments: [false, true])
    func areaCoverageKeepsConcavitiesHolesAndMissingGround(gap: Bool) throws {
        func ring(_ points: [SIMD2<Double>]) -> [OverlayVertex] { points.map { OverlayVertex(point: $0, altitude: 15) } }
        let exterior = ring([.init(0, 0), .init(4, 0), .init(4, 2), .init(2, 2), .init(2, 4), .init(0, 4)])
        let hole = ring([.init(0.3, 0.3), .init(0.8, 0.3), .init(0.8, 0.8), .init(0.3, 0.8)])
        let rings = [exterior, hole]
        let source = try OverlayPolygonTessellator.triangulate(rings: rings)
        var buffers = ridge()
        if gap { buffers.indices = Array(buffers.indices.prefix(6)) }
        let surface = try OverlaySurfaceMesh(terrain: buffers)
        for altitude in [AltitudeReference.clampToGround, .relativeToGround] {
            let reference = try surface.drape(source, altitude: altitude, elevationToY: { ($0 - 100) * 2 })
            let optimized = try surface.drapeArea(source, rings: rings, altitude: altitude, lift: 0, elevationToY: { ($0 - 100) * 2 })
            func area(_ mesh: OverlayMesh) -> Double {
                stride(from: 0, to: mesh.indices.count, by: 3).reduce(0) { sum, i in
                    let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])], c = mesh.positions[Int(mesh.indices[i + 2])]
                    return sum + Double(simd_cross(b - a, c - a).y) / 2
                }
            }
            #expect(abs(area(reference) - area(optimized)) < 1e-5)
            #expect(abs(area(optimized) - (gap ? 7.75 : 11.75)) < 1e-5)
            for position in optimized.positions {
                let expected = 3 - abs(Double(position.x) - 2) * 1.5 + (altitude == .relativeToGround ? 30 : 0)
                #expect(abs(Double(position.y) - expected) < 1e-5)
            }
        }
    }

    @Test(arguments: [4, 7, 37, 300])
    func convexRingCutsKeepHolesWindingAndRelief(count: Int) throws {
        func ring(_ count: Int, center: SIMD2<Double>, radius: Double) -> [OverlayVertex] {
            var result = (0..<count).map { i in
                let angle = Double(i) / Double(count) * .pi * 2
                return OverlayVertex(point: center + SIMD2(cos(angle), sin(angle)) * radius, altitude: 15)
            }
            result.append(result[0]) // Public LinearRing inputs retain their closing vertex.
            return result
        }
        let exterior = ring(count, center: .init(2, 2), radius: 1.9)
        let holes = [ring(7, center: .init(1.6, 2), radius: 0.3), ring(4, center: .init(2.7, 2), radius: 0.1)]
        let surface = try OverlaySurfaceMesh(terrain: ridge())
        for reverse in [false, true] {
            let rings = ([exterior] + holes).map { reverse ? Array($0.reversed()) : $0 }
            let source = try OverlayPolygonTessellator.triangulate(rings: rings)
            let reference = try surface.drape(source, altitude: .relativeToGround, elevationToY: { $0 * 2 - 100 })
            let mesh = try surface.drapeArea(source, rings: rings, altitude: .relativeToGround,
                                           lift: 0, elevationToY: { $0 * 2 - 100 })
            func area(_ mesh: OverlayMesh) -> Double {
                stride(from: 0, to: mesh.indices.count, by: 3).reduce(0) { sum, i in
                    let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])], c = mesh.positions[Int(mesh.indices[i + 2])]
                    return sum + Double(simd_cross(b - a, c - a).y) / 2
                }
            }
            #expect(abs(area(mesh) - area(reference)) < 2e-5)
            for i in stride(from: 0, to: mesh.indices.count, by: 3) {
                let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])], c = mesh.positions[Int(mesh.indices[i + 2])]
                #expect(simd_cross(b - a, c - a).y > 0)
                let center = SIMD2<Double>(Double((a.x + b.x + c.x) / 3), Double((a.z + b.z + c.z) / 3))
                for hole in holes { #expect(OverlayMath.locate(center, in: hole, epsilon: 1e-7) != .inside) }
            }
            for p in mesh.positions { #expect(abs(p.y - (33 - abs(p.x - 2) * 1.5)) < 1e-5) }
        }
    }

    @Test(arguments: [false, true])
    func convexClippingRespectsChunkOutlineAndResidentGaps(gap: Bool) throws {
        let exterior = OverlayFixture.ring([.init(-1, 2), .init(2, -1), .init(5, 2), .init(2, 5)])
        let hole = OverlayFixture.ring([.init(1.6, 1.6), .init(2.4, 1.6), .init(2.4, 2.4), .init(1.6, 2.4)])
        let rings = [exterior, hole]
        let source = try OverlayAreaGeometry.clip(OverlayPolygonTessellator.triangulate(rings: rings), boundary: OverlayFixture.square)
        var buffers = ridge()
        if gap { buffers.indices = Array(buffers.indices.prefix(6)) }
        let surface = try OverlaySurfaceMesh(terrain: buffers)
        let reference = try surface.drape(source, elevationToY: { $0 })
        let optimized = try surface.drapeArea(source, rings: rings, altitude: .clampToGround, lift: 0, elevationToY: { $0 })
        func area(_ mesh: OverlayMesh) -> Double {
            stride(from: 0, to: mesh.indices.count, by: 3).reduce(0) { sum, i in
                let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])], c = mesh.positions[Int(mesh.indices[i + 2])]
                return sum + Double(simd_cross(b - a, c - a).y) / 2
            }
        }
        #expect(!optimized.indices.isEmpty)
        #expect(abs(area(reference) - area(optimized)) < 1e-5)
        #expect(optimized.positions.allSatisfy { $0.x >= 0 && $0.x <= (gap ? 2 : 4) && $0.z >= 0 && $0.z <= 4 })
    }

    @Test(arguments: [false, true])
    func denseRasterBatchesMatchIndependentFragments(clustered: Bool) throws {
        var buffers = ridge()
        buffers.indices.removeLast(3) // Batch queries must not bridge a missing resident face.
        let surface = try OverlaySurfaceMesh(terrain: buffers)
        let source = (0..<2_048).map { i -> OverlayTriangle in
            let x = clustered ? 0.1 + Double(i) / 2_048 * 3.8 : (i.isMultiple(of: 2) ? 0.5 : 3.5)
            let z = 2 + sin(Double(i) / 2_048 * 12) * 1.3
            return .init(a: .init(point: .init(x, z), uv: .init(0, 0), altitude: 10),
                b: .init(point: .init(x, z + 0.001), uv: .init(0, 1), altitude: 20),
                c: .init(point: .init(x + 0.001, z), uv: .init(1, 0), altitude: 30))
        }
        let batch = try surface.drape(source, altitude: .relativeToGround, elevationToY: { $0 * 0.01 - 100 })
        func triangles(_ mesh: OverlayMesh) -> [[UInt32]: Int] {
            var result: [[UInt32]: Int] = [:]
            for start in stride(from: 0, to: mesh.indices.count, by: 3) {
                var key: [UInt32] = []
                for offset in 0..<3 {
                    let i = Int(mesh.indices[start + offset]), p = mesh.positions[i], n = mesh.normals[i], uv = mesh.uvs[i]
                    key += [p.x.bitPattern, p.y.bitPattern, p.z.bitPattern, n.x.bitPattern, n.y.bitPattern, n.z.bitPattern,
                            uv.x.bitPattern, uv.y.bitPattern]
                }
                result[key, default: 0] += 1
            }
            return result
        }
        var expected: [[UInt32]: Int] = [:]
        for start in stride(from: 0, to: source.count, by: 512) {
            let mesh = try surface.drape(Array(source[start..<start + 512]), altitude: .relativeToGround, elevationToY: { $0 * 0.01 - 100 })
            for (key, count) in triangles(mesh) { expected[key, default: 0] += count }
        }
        #expect(!expected.isEmpty)
        #expect(triangles(batch) == expected)
    }

    @Test func rectangularImagesKeepOriginalUVsThroughGroundAndExtentClipping() throws {
        let ring = [OverlayVertex(point: .init(0.5, 0.5), uv: .init(0, 0)),
                    .init(point: .init(3.5, 0.5), uv: .init(1, 0)),
                    .init(point: .init(3.5, 3.5), uv: .init(1, 1)),
                    .init(point: .init(0.5, 3.5), uv: .init(0, 1))]
        let source = try OverlayPolygonTessellator.triangulate(rings: [ring])
        let surface = try OverlaySurfaceMesh(terrain: ridge())
        let mesh = try surface.drapeImage(source, ring: ring, altitude: .clampToGround, lift: 0.001, elevationToY: { $0 })
        var area = 0.0
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])], c = mesh.positions[Int(mesh.indices[i + 2])]
            area += Double(simd_cross(b - a, c - a).y) / 2
        }
        #expect(abs(area - 9) < 1e-5)
        for (p, uv) in zip(mesh.positions, mesh.uvs) {
            #expect(abs(uv.x - (p.x - 0.5) / 3) < 1e-6)
            #expect(abs(uv.y - (p.z - 0.5) / 3) < 1e-6)
            #expect(abs(p.y - (3 - abs(p.x - 2) * 1.5 + 0.001)) < 1e-5)
        }
    }

    @Test func heightRefitsReuseOnlyMatchingHorizontalTopology() throws {
        let buffers = ridge()
        let first = try OverlaySurfaceMesh(terrain: buffers)
        var raised = buffers
        raised.positions = buffers.positions.map { .init($0.x, $0.y * 2, $0.z) }
        let second = try OverlaySurfaceMesh(terrain: raised, reusing: first)
        #expect(second.topologyID == first.topologyID)
        #expect(second.surfaceY(atX: 2, z: 2) == 6)
        #expect(first.surfaceY(atX: 2, z: 2) == 3)
        var steep = buffers
        steep.positions[1].y = 1e9
        let changedCoverage = try OverlaySurfaceMesh(terrain: steep, reusing: first)
        #expect(changedCoverage.topologyID != first.topologyID)
        #expect(changedCoverage.surfaceY(atX: 1, z: 1) == nil)
        raised.positions[0].x -= 1
        let moved = try OverlaySurfaceMesh(terrain: raised, reusing: second)
        #expect(moved.topologyID != second.topologyID)
        raised.indices.removeLast(3)
        let removed = try OverlaySurfaceMesh(terrain: raised, reusing: moved)
        #expect(removed.topologyID != moved.topologyID)
    }

    private func ridge() -> TerrainSolidGenerator.Buffers {
        var buffers = TerrainSolidGenerator.Buffers()
        buffers.positions = [.init(0, 0, 0), .init(2, 3, 0), .init(4, 0, 0),
                             .init(0, 0, 4), .init(2, 3, 4), .init(4, 0, 4)]
        buffers.indices = [0, 3, 1, 1, 3, 4, 1, 4, 2, 2, 4, 5]
        return buffers
    }

    @Test func drapingCutsAtTheRidgeRatherThanSpanningIt() throws {
        let source = try OverlayPolygonTessellator.triangulate(rings: [OverlayFixture.square])
        let surface = try OverlaySurfaceMesh(terrain: ridge())
        let mesh = try surface.drape(source, lift: 0.001, elevationToY: { $0 })
        #expect(!mesh.indices.isEmpty)
        for vertex in mesh.positions {
            let ground = 3 - abs(Double(vertex.x) - 2) * 1.5
            #expect(abs(Double(vertex.y) - ground - 0.001) < 1e-6)
        }
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])], c = mesh.positions[Int(mesh.indices[i + 2])]
            let middle = (a + b + c) / 3
            #expect(abs(Double(middle.y) - (3 - abs(Double(middle.x) - 2) * 1.5) - 0.001) < 1e-6)
            #expect(simd_cross(b - a, c - a).y > 0)
        }
        for (position, uv) in zip(mesh.positions, mesh.uvs) {
            #expect(abs(position.x / 4 - uv.x) < 1e-6)
            #expect(abs(position.z / 4 - uv.y) < 1e-6)
        }
    }

    @Test func altitudeAndTextureAttributesInterpolateAtNewTerrainEdges() throws {
        let source = try OverlayPolygonTessellator.triangulate(rings: [OverlayFixture.square])
        let surface = try OverlaySurfaceMesh(terrain: ridge())
        for altitude in [AltitudeReference.relativeToGround, .absolute] {
            let mesh = try surface.drape(source, altitude: altitude, lift: 0.002, elevationToY: { ($0 - 100) * 2 })
            for vertex in mesh.positions {
                let x = Double(vertex.x), z = Double(vertex.z), geographicAltitude = x + 2 * z
                let expected = altitude == .absolute ? (geographicAltitude - 100) * 2 : 3 - abs(x - 2) * 1.5 + geographicAltitude * 2
                #expect(abs(Double(vertex.y) - expected - 0.002) < 2e-5)
            }
        }
    }

    @Test func holesAndMissingGroundRemainEmptyAfterDraping() throws {
        let hole = OverlayFixture.ring([.init(1, 1), .init(3, 1), .init(3, 3), .init(1, 3)])
        let source = try OverlayPolygonTessellator.triangulate(rings: [OverlayFixture.square, hole])
        var ground = ridge()
        ground.indices = Array(ground.indices.prefix(6)) // only x = 0...2 is resident
        let mesh = try OverlaySurfaceMesh(terrain: ground).drape(source, elevationToY: { $0 })
        var area = 0.0
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let p = (0..<3).map { mesh.positions[Int(mesh.indices[i + $0])] }
            area += Double(simd_cross(p[1] - p[0], p[2] - p[0]).y) / 2
            #expect(p.allSatisfy { $0.x <= 2 })
        }
        #expect(abs(area - 6) < 1e-6)
    }

    @Test func malformedSurfaceAndSmallOutputBudgetsThrow() throws {
        var broken = ridge(); broken.indices[0] = 99
        #expect(throws: OverlayGeometryError.invalidSurface) { try OverlaySurfaceMesh(terrain: broken) }
        let source = try OverlayPolygonTessellator.triangulate(rings: [OverlayFixture.square])
        let surface = try OverlaySurfaceMesh(terrain: ridge(), limits: .init(maxTriangles: 4))
        #expect(throws: OverlayGeometryError.budgetExceeded) { try surface.drape(source, elevationToY: { $0 }) }
        let empty = try OverlaySurfaceMesh(terrain: .init()).drape(source, elevationToY: { $0 })
        #expect(empty.indices.isEmpty)
    }

    @Test func generatedTerrainAndFrozenProjectionDatumDriveTheSameOverlay() throws {
        let field = TerrainHeightField(
            grids: [ElevationGrid(width: 2, height: 2, values: [100, 200, 150, 250])],
            tilePositions: [(x: 0, y: 0)],
            anchor: .init(mosaicMinTile: .zero, tilesWide: 1, tilesTall: 1, extent: .init(4, 4), zoom: 0),
            elevationScale: 0.01, baselineElevation: 125
        )
        let projection = TerrainProjection(heightField: field)
        let boundary = DioramaBoundary.make(shape: .rectangular(width: 4, depth: 4), extent: .init(4, 4))
        let terrain = TerrainSolidGenerator.buildGeometry(heightField: field, boundary: boundary, baseDepth: 1,
                                                          includesWalls: false, includesBottom: false, resolution: 32)
        let ring = OverlayFixture.ring([.init(-1, -1), .init(1, -1), .init(1, 1), .init(-1, 1)])
            .map { OverlayVertex(point: $0.point, uv: $0.uv, altitude: 175) }
        let source = try OverlayPolygonTessellator.triangulate(rings: [ring])
        let surface = try OverlaySurfaceMesh(terrain: terrain.top)
        let absolute = try surface.drape(source, using: projection, altitude: .absolute, lift: 0.001)
        #expect(!absolute.indices.isEmpty)
        #expect(absolute.positions.allSatisfy { abs($0.y - 0.501) < 1e-6 })
        let relative = try surface.drape(source, using: projection, altitude: .relativeToGround, lift: 0.001)
        for vertex in relative.positions {
            let ground = try #require(projection.surfaceY(atX: vertex.x, z: vertex.z))
            #expect(abs(vertex.y - ground - 1.751) < 1e-5)
        }
    }

    @Test func fullResolutionTerrainFitsTheDefaultGeometryBudget() throws {
        let field = TerrainHeightField(grids: [ElevationGrid(width: 2, height: 2, values: [0, 1, 1, 2])],
            tilePositions: [(x: 0, y: 0)], extent: .init(4, 4), elevationScale: 1)
        let boundary = DioramaBoundary.make(shape: .rectangular(width: 4, depth: 4), extent: .init(4, 4))
        let terrain = TerrainSolidGenerator.buildGeometry(heightField: field, boundary: boundary, baseDepth: 1,
            includesWalls: false, includesBottom: false, resolution: 256)
        let ring = OverlayFixture.ring(boundary.vertices.map { SIMD2<Double>($0) })
        let source = try OverlayPolygonTessellator.triangulate(rings: [ring])
        let mesh = try OverlaySurfaceMesh(terrain: terrain.top).drape(source, elevationToY: { $0 })
        var area = 0.0
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])], c = mesh.positions[Int(mesh.indices[i + 2])]
            area += Double(simd_cross(b - a, c - a).y) / 2
        }
        #expect(abs(area - 16) < 1e-6)
    }

    @Test func absoluteAltitudeDoesNotRequireResidentGround() throws {
        let source = try OverlayPolygonTessellator.triangulate(rings: [OverlayFixture.square])
        let mesh = try OverlaySurfaceMesh(terrain: .init()).drape(source, altitude: .absolute, lift: 0.001,
                                                                 elevationToY: { $0 * 2 - 100 })
        #expect(!mesh.indices.isEmpty)
        for vertex in mesh.positions {
            #expect(abs(vertex.y - ((vertex.x + 2 * vertex.z) * 2 - 100) - 0.001) < 1e-5)
        }
    }
}
