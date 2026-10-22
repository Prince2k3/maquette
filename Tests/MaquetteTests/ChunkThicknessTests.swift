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
    @Test("A concave chunk keeps its terrain and matching underside through a slope")
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
        #expect(maximumWallThickness(geometry) <= 0.080001)
        for index in geometry.bottom.positions.indices {
            let top = geometry.top.positions[geometry.bottomSurfaceIndices[index]]
            let bottom = geometry.bottom.positions[index]
            #expect(top.x == bottom.x && top.z == bottom.z)
            #expect(top.y >= bottom.y && top.y - bottom.y <= 0.080001)
            #expect(abs(top.y - field.surfaceY(atX: top.x, z: top.z)) < 1e-5)
        }
        #expect(geometry.bottom.positions.contains { abs($0.y + 0.03) < 1e-5 })
        #expect(geometry.bottom.positions.contains { $0.y > 0 })
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
