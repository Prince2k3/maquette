import RealityKit
import Testing
import simd
@testable import Maquette

@Suite("Shallow terrain chunks")
@MainActor
struct ChunkThicknessTests {
    private func field(elevation: Float) -> TerrainHeightField {
        TerrainHeightField(
            grids: [ElevationGrid(width: 8, height: 8, values: .init(repeating: elevation, count: 64))],
            tilePositions: [(x: 0, y: 0)], extent: SIMD2(repeating: 1),
            elevationScale: 0.001, baselineElevation: 0
        )
    }

    private func maximumWallThickness(_ geometry: TerrainSolidGenerator.Geometry) -> Float {
        stride(from: 0, to: geometry.walls.positions.count, by: 2).map {
            geometry.walls.positions[$0].y - geometry.walls.positions[$0 + 1].y
        }.max() ?? 0
    }

    @Test("A steep raster chunk has a flat underside with bounded padding below its lowest ground")
    func steepReliefKeepsAFlatBase() throws {
        let values = (0..<64).map { Float($0 % 8) / 7 * 800 }
        let terrain = TerrainHeightField(grids: [.init(width: 8, height: 8, values: values)],
            tilePositions: [(0, 0)], extent: SIMD2(repeating: 1), elevationScale: 0.001, baselineElevation: 0)
        let parts = try TerrainSolidGenerator.generate(heightField: terrain,
            boundary: .make(shape: .circular, extent: SIMD2(repeating: 0.8)), baseDepth: 2, resolution: 16)
        var geometry = parts.geometry
        for offset in [SIMD2<Float>.zero, SIMD2(0.07, 0.02), SIMD2(-0.06, -0.03)] {
            TerrainSolidGenerator.resample(&geometry, heightField: terrain, panOffset: offset)
            let minimum = try #require(geometry.top.positions.map(\.y).min())
            let floor = try #require(geometry.bottom.positions.first?.y)
            #expect(geometry.bottom.positions.allSatisfy { abs($0.y - floor) < 1e-6 })
            #expect(minimum >= floor && minimum - floor <= 0.080001)
            #expect(maximumWallThickness(geometry) > 0.08)
            #expect(geometry.bottom.normals.allSatisfy { $0 == SIMD3(0, -1, 0) })
            for point in geometry.top.positions {
                #expect(abs(point.y - terrain.surfaceY(atX: point.x + offset.x, z: point.z + offset.y)) < 1e-5)
            }
            for j in stride(from: 1, to: geometry.walls.positions.count, by: 2) {
                #expect(abs(geometry.walls.positions[j].y - floor) < 1e-6)
            }
        }
    }

    @Test("Terrain below the old requested floor retains relief and closed walls")
    func negativeTerrainKeepsClosedWalls() throws {
        let values = (0..<64).map { Float($0 % 8) / 7 * 100 - 200 }
        let terrain = TerrainHeightField(grids: [.init(width: 8, height: 8, values: values)],
            tilePositions: [(0, 0)], extent: SIMD2(repeating: 1), elevationScale: 0.001, baselineElevation: 0)
        let parts = try TerrainSolidGenerator.generate(heightField: terrain,
            boundary: .make(shape: .circular, extent: SIMD2(repeating: 0.8)), baseDepth: 0.03, resolution: 16)
        let zeroDepth = try TerrainSolidGenerator.generate(heightField: terrain,
            boundary: .make(shape: .circular, extent: SIMD2(repeating: 0.8)), baseDepth: 0, resolution: 16)
        #expect(!zeroDepth.geometry.bottom.indices.isEmpty)
        #expect(!zeroDepth.geometry.walls.indices.isEmpty)
        #expect(!parts.geometry.walls.indices.isEmpty)
        #expect(parts.geometry.top.positions.allSatisfy { $0.y < -0.03 })
        let floor = try #require(parts.geometry.bottom.positions.first?.y)
        for j in stride(from: 1, to: parts.geometry.walls.positions.count, by: 2) {
            #expect(parts.geometry.walls.positions[j].y == floor)
        }
        let material = DioramaMaterials.unlitMaterial(color: .white)
        let entity = try TerrainEntity(parts: parts, surfaceMaterial: material, wallMaterial: material,
            bottomMaterial: material, pannableTerrain: terrain)
        #expect(entity.effectMinimumY == -.infinity)
        let bands = try #require(TerraceBands(dividing: -0.3, 0, into: 12))
        var mesh = IndexedMesh()
        TerraceGeometry.buildSurface(from: parts.geometry.top, bands: bands,
            minimumY: entity.effectMinimumY, into: &mesh)
        #expect(mesh.vertices.allSatisfy { $0.position.y < -0.03 })
    }

    @Test("Shallow wall strata keep a fixed vertical reference while the ground pans")
    func wallTextureDoesNotStretchWithMovingTerrain() throws {
        let parts = try TerrainSolidGenerator.generate(heightField: field(elevation: 1000),
            boundary: .make(shape: .circular, extent: SIMD2(repeating: 1)), baseDepth: 2, resolution: 16)
        var geometry = parts.geometry
        func textureAtHeight(_ geometry: TerrainSolidGenerator.Geometry, _ y: Float) -> Float {
            let top = geometry.walls.positions[0].y, bottom = geometry.walls.positions[1].y
            return geometry.walls.uvs[1].y + (geometry.walls.uvs[0].y - geometry.walls.uvs[1].y)
                * ((y - bottom) / (top - bottom))
        }
        let reference = textureAtHeight(geometry, 0.975)
        TerrainSolidGenerator.resample(&geometry, heightField: field(elevation: 1050), panOffset: SIMD2(0.03, 0))
        #expect(abs(textureAtHeight(geometry, 0.975) - reference) < 1e-5)
    }

    @Test("Raster cut walls have no duplicate perimeter coverage")
    func wallCoverageNeverOverlaps() throws {
        for shape in [DioramaShape.circular, .hexagonal, .rectangular(width: 1, depth: 1)] {
            let boundary = DioramaBoundary.make(shape: shape, extent: SIMD2(repeating: 1))
            for resolution in [16, 32, 64] {
                let parts = try TerrainSolidGenerator.generate(heightField: field(elevation: 100),
                    boundary: boundary, baseDepth: 0.1, resolution: resolution)
                let walls = parts.geometry.walls
                let length = stride(from: 0, to: walls.positions.count, by: 4).reduce(Float(0)) { sum, i in
                    let a = walls.positions[i], b = walls.positions[i + 2]
                    return sum + simd_distance(SIMD2(a.x, a.z), SIMD2(b.x, b.z))
                }
                #expect(abs(length - boundary.perimeter) < 1e-5)
            }
        }
    }

    @Test("An elevated plateau cannot expose a deep block")
    func plateauIsShallow() throws {
        let parts = try TerrainSolidGenerator.generate(
            heightField: field(elevation: 1000),
            boundary: .make(shape: .rectangular(width: 1, depth: 1), extent: SIMD2(repeating: 1)),
            baseDepth: 2, resolution: 8
        )
        #expect(maximumWallThickness(parts.geometry) <= 0.100001)
        #expect(parts.geometry.top.positions.allSatisfy { abs($0.y - 1) < 1e-5 })
        #expect(parts.geometry.bottom.positions.allSatisfy { abs($0.y - 0.9) < 1e-5 })
    }

    @Test("Panning and remapping terrain cannot grow the walls")
    func limitSurvivesResampling() throws {
        let parts = try TerrainSolidGenerator.generate(
            heightField: field(elevation: 1000),
            boundary: .make(shape: .circular, extent: SIMD2(repeating: 0.8)),
            baseDepth: 2, resolution: 12
        )
        var geometry = parts.geometry
        let topology = (geometry.top.indices, geometry.walls.indices, geometry.bottom.indices)
        for elevation in [Float(2000), 50, -300, 4000] {
            TerrainSolidGenerator.resample(&geometry, heightField: field(elevation: elevation), panOffset: SIMD2(0.05, -0.05))
            #expect(maximumWallThickness(geometry) <= 0.080001)
            #expect(maximumWallThickness(geometry) >= 0)
            #expect(geometry.top.indices == topology.0)
            #expect(geometry.walls.indices == topology.1)
            #expect(geometry.bottom.indices == topology.2)
            for index in stride(from: 0, to: geometry.walls.positions.count, by: 2) {
                let bottom = geometry.walls.positions[index + 1]
                #expect(geometry.bottom.positions.contains { simd_distance($0, bottom) < 1e-5 })
            }
        }
    }
    @Test("A concave chunk preserves relief above a flat underside")
    func concaveSlopeKeepsMatchingFaces() throws {
        let values = (0..<64).map { Float($0 % 8) / 7 * 320 - 20 }
        let field = TerrainHeightField(grids: [.init(width: 8, height: 8, values: values)],
            tilePositions: [(0, 0)], extent: SIMD2(repeating: 1), elevationScale: 0.001, baselineElevation: 0)
        let boundary = DioramaBoundary(vertices: [SIMD2(-0.4, -0.4), SIMD2(-0.4, 0.4),
            SIMD2(0, 0.1), SIMD2(0.4, 0.4), SIMD2(0.4, -0.4)])
        let parts = try TerrainSolidGenerator.generate(heightField: field, boundary: boundary,
            baseDepth: 0.03, resolution: 16)
        let geometry = parts.geometry
        #expect(geometry.bottomSurfaceIndices.count == geometry.bottom.positions.count)
        let floor = try #require(geometry.bottom.positions.first?.y)
        let minimum = geometry.top.positions.reduce(Float.infinity) { min($0, $1.y) }
        #expect(minimum - floor <= 0.080001)
        #expect(maximumWallThickness(geometry) > 0.08)
        for index in geometry.bottom.positions.indices {
            let top = geometry.top.positions[geometry.bottomSurfaceIndices[index]]
            let bottom = geometry.bottom.positions[index]
            #expect(top.x == bottom.x && top.z == bottom.z)
            #expect(top.y >= bottom.y)
            #expect(abs(bottom.y - floor) < 1e-6)
            #expect(abs(top.y - field.surfaceY(atX: top.x, z: top.z)) < 1e-5)
        }
        #expect(geometry.bottom.positions.contains { abs($0.y + 0.03) < 1e-5 })
        #expect(geometry.bottom.positions.allSatisfy { abs($0.y - floor) < 1e-6 })
    }

    @Test("Underside GPU bounds and metadata publish with their matching overlays")
    func deferredUndersidePublication() async throws {
        let initial = field(elevation: 1000), replacement = field(elevation: 2000)
        let boundary = DioramaBoundary.make(shape: .rectangular(width: 1, depth: 1), extent: SIMD2(repeating: 1))
        let parts = try TerrainSolidGenerator.generate(heightField: initial, boundary: boundary, baseDepth: 2, resolution: 8)
        let material = DioramaMaterials.unlitMaterial(color: .white)
        let terrain = try TerrainEntity(parts: parts, surfaceMaterial: material, wallMaterial: material,
            bottomMaterial: material, pannableTerrain: initial)
        let root = DioramaEntity(); root.setTerrain(terrain)
        let configuration = DioramaConfiguration(center: initial.anchor.coordinate(forDioramaX: 0, z: 0).clLocationCoordinate,
            radiusMeters: 1000, shape: .rectangular(width: 1, depth: 1), physicalSize: 1)
        let proxy = DioramaProxy(configuration: configuration, projection: TerrainProjection(heightField: initial))
        let content = DioramaContentGroup { DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "park") }
        root.applyContent(content, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let model = try #require(terrain.bottom)
        let resource = try #require(model.model?.mesh)
        #expect(abs(resource.bounds.min.y - 0.9) < 1e-5)
        terrain.setTerrain(replacement, surfaceMaterial: nil)
        #expect(terrain.isPanPresentationDeferred)
        #expect(abs(terrain.baseDepth + 0.9) < 1e-5)
        #expect(abs(resource.bounds.min.y - 0.9) < 1e-5)
        root.applyContent(content, using: DioramaProxy(configuration: configuration,
            projection: TerrainProjection(heightField: replacement)), physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(!terrain.isPanPresentationDeferred)
        #expect(abs(terrain.baseDepth + 1.9) < 1e-5)
        #expect(abs(resource.bounds.min.y - 1.9) < 1e-5)
        #expect(terrain.bottom?.model?.mesh === resource)
    }

    @Test("Terrace plinth follows its flat effect floor and restores after removal")
    func terracePlinthTracksAndRestores() throws {
        let values = (0..<64).map { Float($0 % 8) / 7 * 800 + 100 }
        let field = TerrainHeightField(grids: [.init(width: 8, height: 8, values: values)],
            tilePositions: [(0, 0)], extent: SIMD2(repeating: 1), elevationScale: 0.001, baselineElevation: 0)
        let boundary = DioramaBoundary.make(shape: .circular, extent: SIMD2(repeating: 0.8))
        let parts = try TerrainSolidGenerator.generate(heightField: field, boundary: boundary, baseDepth: 2, resolution: 16)
        let material = DioramaMaterials.unlitMaterial(color: .white)
        let terrain = try TerrainEntity(parts: parts, surfaceMaterial: material, wallMaterial: material,
            bottomMaterial: material, pannableTerrain: field)
        let root = DioramaEntity(); root.setTerrain(terrain)
        let base = Entity(); base.position.y = -terrain.baseDepth; root.setBase(base)
        let pass = TerraceEffectPass(style: TerraceStyle(steps: .elevationMeters(333), colors: [.gray, .white]))
        let context = DioramaEffectContext(boundary: boundary, elevationScale: 0.001, baselineElevation: 0, imagery: nil)
        let relief = try #require(TerraceGeometry.relief(of: parts.geometry.top.positions))
        let bands = try #require(TerraceBands(everyMeters: 333, elevationScale: 0.001, baselineElevation: 0,
            lower: relief.lower, upper: relief.upper))
        pass.apply(to: root, context: context)
        for offset in [SIMD2<Float>.zero, SIMD2(0.06, 0.02), SIMD2(-0.04, 0.03)] {
            terrain.setPanOffset(offset)
            pass.refresh(on: root, context: context)
            let expected = TerraceGeometry.flatFloor(bottom: try #require(terrain.bottomBuffers),
                surface: try #require(terrain.surfaceBuffers), bands: bands, minimumY: -.infinity)
            #expect(abs(base.position.y - expected) < 1e-5)
        }
        pass.revert(from: root)
        #expect(abs(base.position.y + terrain.baseDepth) < 1e-5)
    }

    @Test("Terraces share one flat closing plane below their lowest step")
    func terraceSlopesKeepAFlatBottom() throws {
        let values = (0..<64).map { Float($0 % 8) / 7 * 800 + 100 }
        let terrain = TerrainHeightField(grids: [.init(width: 8, height: 8, values: values)],
            tilePositions: [(0, 0)], extent: SIMD2(repeating: 1), elevationScale: 0.001, baselineElevation: 0)
        let parts = try TerrainSolidGenerator.generate(heightField: terrain,
            boundary: .make(shape: .circular, extent: SIMD2(repeating: 0.8)), baseDepth: 2, resolution: 16)
        let bands = try #require(TerraceBands(dividing: 0, 1, into: 3))
        let floor = TerraceGeometry.flatFloor(bottom: parts.geometry.bottom, surface: parts.geometry.top,
            bands: bands, minimumY: -2)
        var mesh = IndexedMesh()
        TerraceGeometry.buildBottom(from: parts.geometry.bottom, surface: parts.geometry.top,
            surfaceIndices: parts.geometry.bottomSurfaceIndices, bands: bands, minimumY: -2, into: &mesh)
        #expect(mesh.vertices.allSatisfy { abs($0.position.y - floor) < 1e-6 })
        TerraceGeometry.buildWalls(from: parts.geometry.walls, bands: bands, baseDepth: 2,
            wallHeight: parts.resampling.wallHeight, floorY: floor, into: &mesh)
        for index in stride(from: 1, to: mesh.vertices.count, by: 2) {
            #expect(abs(mesh.vertices[index].position.y - floor) < 1e-6)
            #expect(mesh.vertices[index - 1].position.y >= floor)
        }
    }

    @Test("Terrace rounding cannot push a shallow underside through its surface")
    func terraceUndersideMeetsLoweredRim() throws {
        let parts = try TerrainSolidGenerator.generate(heightField: field(elevation: 1000),
            boundary: .make(shape: .circular, extent: SIMD2(repeating: 1)), baseDepth: 2, resolution: 8)
        let bands = try #require(TerraceBands(dividing: 0, 2, into: 3))
        var mesh = IndexedMesh()
        TerraceGeometry.buildBottom(from: parts.geometry.bottom, surface: parts.geometry.top,
            surfaceIndices: parts.geometry.bottomSurfaceIndices, bands: bands, minimumY: -2, into: &mesh)
        let terracedY = bands.level(ofRung: bands.rung(of: 1))
        #expect(mesh.vertices.allSatisfy { abs($0.position.y - terracedY) < 1e-5 })
        #expect(mesh.indices == parts.geometry.bottom.indices)
        TerraceGeometry.buildWalls(from: parts.geometry.walls, bands: bands,
            baseDepth: 2, wallHeight: 0.1, into: &mesh)
        for index in stride(from: 0, to: mesh.vertices.count, by: 2) {
            #expect(abs(mesh.vertices[index].position.y - mesh.vertices[index + 1].position.y) < 1e-5)
        }
    }

    @Test("A moving chunk fails coherently if its underside GPU buffer cannot be created")
    func allocationFailureCannotLeaveAStaticUnderside() throws {
        enum AllocationFailure: Error { case bottom }
        let field = field(elevation: 1000)
        let parts = try TerrainSolidGenerator.generate(heightField: field,
            boundary: .make(shape: .circular, extent: SIMD2(repeating: 1)), baseDepth: 2, resolution: 8)
        let material = DioramaMaterials.unlitMaterial(color: .white)
        var attempts = 0
        #expect(throws: AllocationFailure.self) {
            _ = try TerrainEntity(parts: parts, surfaceMaterial: material, wallMaterial: material,
                bottomMaterial: material, pannableTerrain: field) { buffers, name in
                    attempts += 1
                    if name == "terrainBottom" { throw AllocationFailure.bottom }
                    return try ChunkSurfaceMesh(buffers: buffers, name: name)
                }
        }
        #expect(attempts == 3)
    }

}
