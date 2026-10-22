import CoreGraphics
import Observation
import RealityKit
import SwiftUI
import Synchronization
import Testing
@testable import Maquette

@MainActor
enum OverlayRenderFixture {
    static func make(resolution: Int = 8) throws -> (DioramaEntity, DioramaProxy) {
        let center = Coordinate(latitude: 36, longitude: -112)
        let anchor = TerrainAnchor(centeredOn: center, zoom: 10, extent: .init(1, 1), radiusMeters: 1000)
        let tile = TileMath.tileXY(for: center, zoom: 10)
        let field = TerrainHeightField(grids: [.init(width: 2, height: 2, values: [100, 100, 100, 100])],
            tilePositions: [(tile.x, tile.y)], anchor: anchor, elevationScale: 0.0005)
        let configuration = DioramaConfiguration(center: center.clLocationCoordinate, radiusMeters: 1000,
            shape: .rectangular(width: 1, depth: 1), physicalSize: 1)
        let parts = try TerrainSolidGenerator.generate(heightField: field, boundary: configuration.boundary, baseDepth: 0.1, resolution: resolution)
        let root = DioramaEntity()
        root.setTerrain(TerrainEntity(parts: parts, surfaceMaterial: DioramaMaterials.unlitMaterial(color: .white),
                                     wallMaterial: nil, bottomMaterial: nil, pannableTerrain: field))
        return (root, DioramaProxy(configuration: configuration, projection: TerrainProjection(heightField: field)))
    }
    static func polygon(_ proxy: DioramaProxy, hole: Bool = false) -> Maquette.Polygon {
        let terrain = proxy.projection as! TerrainProjection
        func ring(_ size: Double) -> LinearRing {
            LinearRing([SIMD2(-size, -size), .init(size, -size), .init(size, size), .init(-size, size)]
                .map { terrain.anchor.coordinate(forDioramaX: $0.x, z: $0.y) })
        }
        return Maquette.Polygon(exterior: ring(0.3), holes: hole ? [ring(0.1)] : [])
    }
    static func image() throws -> CGImage {
        try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    }
}

@Suite("Diorama overlay reconciliation")
@MainActor
struct DioramaOverlayRenderingTests {
    @Test func convexFillBudgetsResidentOutputInsteadOfUnusedTessellation() throws {
        let (root, proxy) = try OverlayRenderFixture.make(resolution: 2)
        let projection = try #require(proxy.projection as? TerrainProjection)
        let buffers = try #require(root.terrain?.surfaceBuffers)
        let cap = buffers.indices.count / 3
        let surface = try OverlaySurfaceMesh(terrain: buffers, limits: .init(maxTriangles: cap))
        let ring = LinearRing((0..<300).map { i in
            let angle = Double(i) / 300 * 2 * Double.pi
            return projection.anchor.coordinate(forDioramaX: cos(angle) * 0.8, z: sin(angle) * 0.8)
        })
        let layers = try DioramaOverlayGeometryBuilder.build(shape: .polygon(.init(exterior: ring)),
            style: .init(), proxy: proxy, surface: surface, physicalSize: 1)
        let mesh = try #require(layers.first?.mesh)
        #expect(mesh.indices.count == buffers.indices.count)
        var area: Float = 0
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.positions[Int(mesh.indices[i])], b = mesh.positions[Int(mesh.indices[i + 1])]
            let c = mesh.positions[Int(mesh.indices[i + 2])]
            area += simd_cross(b - a, c - a).y / 2
        }
        #expect(abs(area - 1) < 1e-5)
        #expect(mesh.positions.allSatisfy { abs($0.y - 0.002) < 1e-5 })
    }

    @Test func identicalFootprintsShareWorkWithoutSharingMaterialsOrCancellation() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let bounds = try #require(GeographicBounds(enclosing: OverlayRenderFixture.polygon(proxy).exterior!.coordinates))
        let pixels = try OverlayRenderFixture.image()
        func content(_ count: Int) -> DioramaContentGroup {
            DioramaContentGroup {
                for index in 0..<count {
                    DioramaImageOverlay(image: .init(id: "image-\(index)", revision: "1", image: pixels),
                                        bounds: bounds, id: "overlay-\(index)").opacity(Double(index + 1) / 4)
                }
            }
        }
        root.applyContent(content(4), using: proxy, physicalSize: 1)
        #expect(root.overlayRenderer.geometryTaskCount == 1)
        root.applyContent(content(1), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.diagnostics.isEmpty)
        #expect(root.overlayRenderer.records["overlay-0"]?.entity.isEnabled == true)
        #expect(root.overlayRenderer.records.count == 1)
        root.applyContent(content(4), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.geometryTaskCount == 1)
        #expect(root.overlayRenderer.textureUploadCount == 4)
        #expect(root.overlayRenderer.records.count == 4)
        let models = root.overlayRenderer.records.values.compactMap { $0.layers[.image]?.model }
        #expect(Set(models.map(ObjectIdentifier.init)).count == 4)
    }

    @Test func imageMeshesShareUploadsAndDetachWhenOneFootprintChanges() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let pixels = try OverlayRenderFixture.image()
        let bounds = try #require(GeographicBounds(enclosing: OverlayRenderFixture.polygon(proxy).exterior!.coordinates))
        let smaller = GeographicBounds(west: bounds.west, south: bounds.south,
            east: bounds.center.longitude, north: bounds.north)
        func content(_ edited: Bool) -> DioramaContentGroup {
            DioramaContentGroup {
                for i in 0..<4 {
                    DioramaImageOverlay(image: .init(id: "image-\(i)", revision: "1", image: pixels),
                        bounds: edited && i == 0 ? smaller : bounds, id: "overlay-\(i)").opacity(Double(i + 1) / 4)
                }
            }
        }
        root.applyContent(content(false), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let parts = try (0..<4).map { try #require(root.overlayRenderer.records["overlay-\($0)"]?.layers[.image]) }
        #expect(Set(parts.map { ObjectIdentifier($0.resource) }).count == 1)
        #expect(root.overlayRenderer.meshUploadCount == 1)
        let keptPositions = parts[1].mesh.positions
        let keptResource = parts[1].resource
        root.applyContent(content(true), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(parts[0].resource !== keptResource)
        #expect(parts[1].resource === keptResource)
        #expect(parts[1].mesh.positions == keptPositions)
        #expect(parts[0].mesh.positions != keptPositions)
        root.applyContent(content(false), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(Set(parts.map { ObjectIdentifier($0.resource) }).count == 1)
        #expect(root.overlayRenderer.textureUploadCount == 4)
        #expect(root.overlayRenderer.meshUploadCount == 2)
        let base = try #require(proxy.projection as? TerrainProjection)
        let field = TerrainHeightField(grids: base.heightField.grids, tilePositions: base.heightField.tilePositions,
            anchor: base.anchor.scaled(by: 1.1), elevationScale: base.heightField.elevationScale / 1.1,
            baselineElevation: base.heightField.baselineElevation)
        root.terrain?.setTerrain(field, surfaceMaterial: nil, groundScale: 1.1)
        root.applyContent(content(false), using: DioramaProxy(configuration: proxy.configuration,
            projection: TerrainProjection(heightField: field)), physicalSize: 1)
        #expect(root.overlayRenderer.records.values.allSatisfy { $0.entity.isEnabled })
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.meshUploadCount == 3)
        #expect(Set(parts.map { ObjectIdentifier($0.resource) }).count == 1)
        #expect(root.overlayRenderer.records.values.allSatisfy { $0.entity.isEnabled })
    }

    @Test func invalidOpacityDoesNotPoisonSharedGeometry() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let polygon = OverlayRenderFixture.polygon(proxy)
        func content(_ invalidOpacity: Double?, includeValid: Bool = true) -> DioramaContentGroup {
            DioramaContentGroup {
                if let invalidOpacity {
                    DioramaPolygon(polygon, id: "invalid").opacity(invalidOpacity)
                }
                if includeValid { DioramaPolygon(polygon, id: "valid") }
            }
        }
        root.applyContent(content(.nan), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.geometryTaskCount == 1)
        #expect(root.overlayRenderer.diagnostics["invalid"] == .nonFiniteInput)
        #expect(root.overlayRenderer.records["invalid"]?.entity.isEnabled == false)
        #expect(root.overlayRenderer.records["valid"]?.entity.isEnabled == true)
        root.applyContent(content(nil), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.records["valid"]?.entity.isEnabled == true)
        root.applyContent(content(.infinity), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        root.applyContent(content(1), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.diagnostics.isEmpty)
        #expect(root.overlayRenderer.records["invalid"]?.entity.isEnabled == true)
        #expect(root.overlayRenderer.geometryTaskCount == 1)
    }

    @Test func warmPanPublishesCoherentClippedGeometryWithoutABlankFrame() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let content = DioramaContentGroup {
            DioramaPolygon(OverlayRenderFixture.polygon(proxy, hole: true), id: "park").fill(.green)
        }
        root.applyContent(content, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let record = try #require(root.overlayRenderer.records["park"])
        let part = try #require(record.layers[.fill])
        let resource = part.model.model?.mesh
        var projection = try #require(proxy.projection as? TerrainProjection)
        for offset: Float in [0.02, 0.04, -0.01, 0] {
            let previous = part.mesh.positions
            let presented = root.terrain?.presentedPanOffset
            projection.panOffset = .init(offset, offset / 2)
            root.terrain?.setPanOffset(projection.panOffset)
            let moved = DioramaProxy(configuration: proxy.configuration, projection: projection)
            root.applyContent(content, using: moved, physicalSize: 1)
            // Keep the last coherent frame visible while parallel replacement work finishes.
            #expect(record.entity.isEnabled)
            #expect(part.mesh.positions == previous)
            #expect(root.terrain?.presentedPanOffset == presented)
            #expect(root.terrain?.isPanPresentationDeferred == true)
            await root.overlayRenderer.waitUntilIdle()
            #expect(root.terrain?.presentedPanOffset == projection.panOffset)
            #expect(root.terrain?.isPanPresentationDeferred == false)
            #expect(record.entity.isEnabled)
            #expect(record.appliedKey == record.key)
            #expect(part.mesh.positions != previous)
            #expect(part.model.model?.mesh === resource)
            let expected = try DioramaOverlayGeometryBuilder.build(shape: record.input.shape,
                style: record.input.annotation.style, proxy: moved,
                surface: OverlaySurfaceMesh(terrain: #require(root.terrain?.surfaceBuffers)), physicalSize: 1)
            #expect(part.mesh.positions == expected.first(where: { $0.kind == .fill })?.mesh.positions)
            #expect(part.mesh.indices == expected.first(where: { $0.kind == .fill })?.mesh.indices)
        }
        #expect(root.overlayRenderer.diagnostics.isEmpty)
    }

    @Test func groundZoomRetainsThePreviousCompleteFrameUntilAllOverlaysAreReady() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let content = DioramaContentGroup {
            DioramaPolygon(OverlayRenderFixture.polygon(proxy, hole: true), id: "park").fill(.green)
            DioramaCircle(center: .init(latitude: 36, longitude: -112), radius: 40, id: "circle")
        }
        root.applyContent(content, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let base = try #require(proxy.projection as? TerrainProjection)
        let record = try #require(root.overlayRenderer.records["park"])
        let part = try #require(record.layers[.fill])
        let resource = part.model.model?.mesh
        for scale: Float in [1.05, 1.1, 1.02, 1] {
            let previous = part.mesh.positions
            let presentedRevision = root.terrain?.presentedSurfaceRevision
            let field = TerrainHeightField(grids: base.heightField.grids,
                tilePositions: base.heightField.tilePositions, anchor: base.anchor.scaled(by: Double(scale)),
                elevationScale: base.heightField.elevationScale / scale,
                baselineElevation: base.heightField.baselineElevation + (scale - 1) * 10)
            root.terrain?.setTerrain(field, surfaceMaterial: nil, panOffset: .init(0.01 / scale, 0), groundScale: scale)
            let moved = DioramaProxy(configuration: proxy.configuration,
                projection: TerrainProjection(heightField: field, panOffset: .init(0.01 / scale, 0)))
            root.applyContent(content, using: moved, physicalSize: 1)
            #expect(root.overlayRenderer.records.values.allSatisfy { $0.entity.isEnabled })
            #expect(root.terrain?.isPanPresentationDeferred == true)
            #expect(root.terrain?.presentedSurfaceRevision == presentedRevision)
            #expect(part.mesh.positions == previous)
            await root.overlayRenderer.waitUntilIdle()
            #expect(root.overlayRenderer.records.values.allSatisfy { $0.entity.isEnabled && $0.appliedKey == $0.key })
            #expect(root.terrain?.isPanPresentationDeferred == false)
            #expect(root.terrain?.presentedSurfaceRevision == record.appliedKey?.context.revision)
            #expect(part.model.model?.mesh === resource)
            let expected = try DioramaOverlayGeometryBuilder.build(shape: record.input.shape,
                style: record.input.annotation.style, proxy: moved,
                surface: OverlaySurfaceMesh(terrain: #require(root.terrain?.surfaceBuffers)), physicalSize: 1)
            #expect(part.mesh.positions == expected.first(where: { $0.kind == .fill })?.mesh.positions)
        }
    }

    @Test func pendingPanContentEditsCannotReviveAnObsoleteShape() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let polygon = OverlayRenderFixture.polygon(proxy)
        let original = DioramaContentGroup {
            DioramaPolygon(polygon, id: "changed")
            DioramaPolygon(polygon, id: "kept")
        }
        root.applyContent(original, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        var projection = try #require(proxy.projection as? TerrainProjection)
        projection.panOffset = .init(0.03, 0)
        root.terrain?.setPanOffset(projection.panOffset)
        let moved = DioramaProxy(configuration: proxy.configuration, projection: projection)
        root.applyContent(original, using: moved, physicalSize: 1)
        let changed = DioramaContentGroup {
            DioramaCircle(center: .init(latitude: 36, longitude: -112), radius: -1, id: "changed")
            DioramaPolygon(polygon, id: "kept").fill(.orange)
        }
        for _ in 0..<2 {
            root.applyContent(changed, using: moved, physicalSize: 1)
            #expect(root.overlayRenderer.records["changed"]?.entity.isEnabled == false)
            #expect(root.overlayRenderer.records["kept"]?.entity.isEnabled == true)
        }
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.diagnostics["changed"] != nil)
        #expect(root.overlayRenderer.records["kept"]?.appliedKey == root.overlayRenderer.records["kept"]?.key)
        #expect(root.terrain?.presentedPanOffset == projection.panOffset)
    }

    @Test func removingPanOverlaysCommitsTerrainAndDoesNotRestoreOldPins() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let content = DioramaContentGroup {
            DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "park")
            DioramaMarker("Old", coordinate: .init(latitude: 36, longitude: -112), id: "old")
        }
        root.applyContent(content, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        var projection = try #require(proxy.projection as? TerrainProjection)
        projection.panOffset = .init(0.03, 0)
        root.terrain?.setPanOffset(projection.panOffset)
        let moved = DioramaProxy(configuration: proxy.configuration, projection: projection)
        root.applyContent(content, using: moved, physicalSize: 1)
        let oldTasks = root.overlayRenderer.records.values.compactMap(\.task)
        root.applyContent(DioramaContentGroup {
            DioramaMarker("New", coordinate: .init(latitude: 36, longitude: -112), id: "new")
        }, using: moved, physicalSize: 1)
        for task in oldTasks { await task.value }
        #expect(root.overlayRenderer.records.isEmpty)
        #expect(root.markerEntities.keys.sorted() == ["new"])
        #expect(root.terrain?.isPanPresentationDeferred == false)
        #expect(root.terrain?.presentedPanOffset == projection.panOffset)
    }

    @Test func substrateReplacementCannotOverwriteAPanDrainedByItsCompletion() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let content = DioramaContentGroup { DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "park") }
        root.applyContent(content, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        var a = try #require(proxy.projection as? TerrainProjection)
        a.panOffset = .init(0.02, 0)
        root.terrain?.setPanOffset(a.panOffset)
        root.applyContent(content, using: DioramaProxy(configuration: proxy.configuration, projection: a), physicalSize: 1)
        let replacement = TerrainHeightField(grids: a.heightField.grids, tilePositions: a.heightField.tilePositions,
            anchor: a.anchor, elevationScale: a.heightField.elevationScale,
            baselineElevation: a.heightField.baselineElevation + 10)
        let queued = TerrainProjection(heightField: replacement, panOffset: .init(0.04, 0))
        root.panPresentationCompletion = { drainQueued in
            guard drainQueued else { return }
            root.terrain?.setPanOffset(queued.panOffset)
            root.applyContent(content, using: DioramaProxy(configuration: proxy.configuration, projection: queued), physicalSize: 1)
        }
        root.terrain?.setTerrain(replacement, surfaceMaterial: nil)
        root.applyContent(content, using: DioramaProxy(configuration: proxy.configuration,
            projection: TerrainProjection(heightField: replacement, panOffset: a.panOffset)), physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let record = try #require(root.overlayRenderer.records["park"])
        #expect(root.terrain?.panOffset == queued.panOffset)
        #expect(record.key?.context.pan == queued.panOffset)
        #expect(record.appliedKey == record.key)
        #expect(root.terrain?.presentedPanOffset == queued.panOffset)
    }

    @Test func rollingTerrainKeepsItsMatchingOverlaysVisibleUntilReplacementIsReady() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let content = DioramaContentGroup { DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "park") }
        root.applyContent(content, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let record = try #require(root.overlayRenderer.records["park"])
        let base = try #require(proxy.projection as? TerrainProjection)
        let tile = TileMath.tileXY(for: Coordinate(proxy.configuration.center), zoom: base.anchor.zoom)
        let field = TerrainHeightField(grids: [.init(width: 2, height: 2, values: [200, 200, 200, 200])],
            tilePositions: [(tile.x, tile.y)], anchor: base.anchor,
            elevationScale: base.heightField.elevationScale, baselineElevation: base.heightField.baselineElevation)
        let revision = record.appliedKey?.context.revision
        let old = record.layers[.fill]?.mesh.positions
        let previousMaterial = try #require(root.terrain?.surface?.model?.materials.first as? UnlitMaterial)
        let nextMaterial = DioramaMaterials.unlitMaterial(color: .blue)
        root.terrain?.setTerrain(field, surfaceMaterial: nextMaterial)
        let heldMaterial = try #require(root.terrain?.surface?.model?.materials.first as? UnlitMaterial)
        #expect(heldMaterial.color.tint.cgColor.components == previousMaterial.color.tint.cgColor.components)
        root.applyContent(content, using: DioramaProxy(configuration: proxy.configuration,
            projection: TerrainProjection(heightField: field)), physicalSize: 1)
        #expect(record.entity.isEnabled)
        #expect(record.layers[.fill]?.mesh.positions == old)
        #expect(record.appliedKey?.context.revision == revision)
        #expect(root.terrain?.isPanPresentationDeferred == true)
        await root.overlayRenderer.waitUntilIdle()
        #expect(record.entity.isEnabled)
        #expect(record.appliedKey == record.key)
        #expect(record.layers[.fill]?.mesh.positions != old)
        #expect(root.terrain?.isPanPresentationDeferred == false)
        let installed = try #require(root.terrain?.surface?.model?.materials.first as? UnlitMaterial)
        #expect(installed.color.tint.cgColor.components == nextMaterial.color.tint.cgColor.components)
        // A zoom superseding the next staged roll must keep that roll's imagery.
        let latest = DioramaMaterials.unlitMaterial(color: .red)
        root.terrain?.setTerrain(field, surfaceMaterial: latest)
        root.terrain?.setTerrain(field, surfaceMaterial: nil, groundScale: 2)
        #expect(root.terrain?.isPanPresentationDeferred == true)
        root.applyContent(content, using: DioramaProxy(configuration: proxy.configuration,
            projection: TerrainProjection(heightField: field)), physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let zoomed = try #require(root.terrain?.surface?.model?.materials.first as? UnlitMaterial)
        #expect(zoomed.color.tint.cgColor.components == latest.color.tint.cgColor.components)
        #expect(root.terrain?.isPanPresentationDeferred == false)
    }

    @Test func heightOnlyRebuildRetainsInstalledMaterialAndResource() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let polygon = OverlayRenderFixture.polygon(proxy)
        func content(_ color: Color) -> DioramaContentGroup {
            DioramaContentGroup { DioramaPolygon(polygon, id: "park").fill(color) }
        }
        root.applyContent(content(.green), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let record = try #require(root.overlayRenderer.records["park"])
        let part = try #require(record.layers[.fill])
        let resource = try #require(part.model.model?.mesh)
        let firstY = try #require(part.mesh.positions.first?.y)
        let materials = root.overlayRenderer.materialUpdateCount
        let selectionWrites = root.overlayRenderer.selectionComponentUpdateCount
        let projection = try #require(proxy.projection as? TerrainProjection)
        let tile = TileMath.tileXY(for: Coordinate(proxy.configuration.center), zoom: projection.anchor.zoom)
        let field = TerrainHeightField(grids: [.init(width: 2, height: 2, values: [200, 200, 200, 200])],
            tilePositions: [(tile.x, tile.y)], anchor: projection.anchor,
            elevationScale: projection.heightField.elevationScale, baselineElevation: projection.heightField.baselineElevation)
        root.terrain?.setTerrain(field, surfaceMaterial: nil, panOffset: .zero, groundScale: 1)
        let moved = DioramaProxy(configuration: proxy.configuration, projection: TerrainProjection(heightField: field))
        root.applyContent(content(.green), using: moved, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.records["park"] === record)
        #expect(part.model.model?.mesh === resource)
        #expect(part.mesh.positions.first?.y != firstY)
        #expect(root.overlayRenderer.materialUpdateCount == materials)
        #expect(root.overlayRenderer.selectionComponentUpdateCount == selectionWrites)
        let builds = root.overlayRenderer.geometryBuildCount
        root.applyContent(content(.red), using: moved, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.materialUpdateCount == materials + 1)
        #expect(root.overlayRenderer.geometryBuildCount == builds)
        #expect(record.entity.isEnabled)
    }

    @Test func asyncCompletionInvalidatesAnIdleSceneObserver() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let changed = Mutex(false)
        withObservationTracking {
            _ = root.overlayRenderer.geometryBuildCount
        } onChange: {
            changed.withLock { $0 = true }
        }
        root.applyContent(DioramaContentGroup {
            DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "async").fill(.green)
        }, using: proxy, physicalSize: 1)
        #expect(!changed.withLock { $0 })
        await root.overlayRenderer.waitUntilIdle()
        #expect(changed.withLock { $0 })
        #expect(root.overlayRenderer.geometryBuildCount == 1)
        #expect(root.overlayRenderer.records["async"]?.entity.isEnabled == true)

        let unchanged = Mutex(false)
        withObservationTracking {
            _ = root.overlayRenderer.geometryBuildCount
        } onChange: {
            unchanged.withLock { $0 = true }
        }
        root.applyContent(DioramaContentGroup {
            DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "async").fill(.orange)
        }, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(!unchanged.withLock { $0 })
    }

    @Test func polygonAndGeoJSONShareRenderingAndAppearanceEditsKeepGeometry() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let polygon = OverlayRenderFixture.polygon(proxy, hole: true)
        func content(_ color: Color) -> DioramaContentGroup {
            DioramaContentGroup { DioramaPolygon(polygon, id: "park").fill(color).stroke(.orange, width: .physicalMeters(0.003)) }
        }
        root.applyContent(content(.green), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let first = try #require(root.overlayRenderer.records["park"])
        #expect(first.layers.count == 2)
        let count = root.overlayRenderer.geometryBuildCount
        root.applyContent(content(.red), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.records["park"] === first)
        #expect(root.overlayRenderer.geometryBuildCount == count)
        root.applyContent(DioramaContentGroup { DioramaFeature(Feature(geometry: .polygon(polygon)), id: "geo") }, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.records["park"] == nil)
        #expect(root.overlayRenderer.records["geo"]?.layers.isEmpty == false)
    }
    @Test func imageOpacityReusesTextureAndRevisionReplacesOnlyTheTexture() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let bounds = try #require(GeographicBounds(enclosing: OverlayRenderFixture.polygon(proxy).exterior!.coordinates))
        let pixels = try OverlayRenderFixture.image()
        func content(_ revision: String, _ opacity: Double) -> DioramaContentGroup {
            DioramaContentGroup {
                DioramaImageOverlay(image: .init(id: "survey", revision: revision, image: pixels, attribution: "Survey team"),
                                    bounds: bounds, id: "image").opacity(opacity)
            }
        }
        root.applyContent(content("1", 0.5), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let builds = root.overlayRenderer.geometryBuildCount
        #expect(root.overlayRenderer.textureUploadCount == 1)
        root.applyContent(content("1", 0.9), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.geometryBuildCount == builds)
        #expect(root.overlayRenderer.textureUploadCount == 1)
        root.applyContent(content("2", 0.9), using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.geometryBuildCount == builds)
        #expect(root.overlayRenderer.textureUploadCount == 2)
    }
    @Test func removedOrSupersededWorkCannotRestoreOldContent() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        root.applyContent(DioramaContentGroup { DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "old") }, using: proxy, physicalSize: 1)
        let pending = root.overlayRenderer.records["old"]?.task
        root.applyContent(.empty, using: proxy, physicalSize: 1)
        await pending?.value
        #expect(root.overlayRenderer.records.isEmpty)
        #expect(!root.children.contains { $0.name == "Overlay_old" })
    }
    @Test func circleProducesClippedFillAndOutline() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        root.applyContent(DioramaContentGroup {
            DioramaCircle(center: .init(latitude: 36, longitude: -112), radius: 300, id: "circle")
                .fill(.blue.opacity(0.2)).stroke(.blue, width: .geographicMeters(10))
        }, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.records["circle"]?.layers.count == 2)
        #expect(root.overlayRenderer.diagnostics.isEmpty)
    }
    @Test func supersededGeometryAndInvalidContentCannotLeaveStaleShapes() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        root.applyContent(DioramaContentGroup { DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "same") }, using: proxy, physicalSize: 1)
        let old = root.overlayRenderer.records["same"]?.task
        root.applyContent(DioramaContentGroup {
            DioramaCircle(center: .init(latitude: 36, longitude: -112), radius: 100, id: "same")
        }, using: proxy, physicalSize: 1)
        await old?.value
        await root.overlayRenderer.waitUntilIdle()
        let record = try #require(root.overlayRenderer.records["same"])
        #expect(record.appliedKey == record.key)
        #expect(record.input.shape == .circle(.init(latitude: 36, longitude: -112), 100))
        root.applyContent(DioramaContentGroup {
            DioramaCircle(center: .init(latitude: 36, longitude: -112), radius: -1, id: "same")
        }, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.diagnostics["same"] != nil)
        #expect(!record.entity.isEnabled)
    }
    @Test func unavailableGroundSurfaceProducesDiagnosticWithoutFallback() async throws {
        let (_, proxy) = try OverlayRenderFixture.make()
        let root = DioramaEntity()
        root.applyContent(DioramaContentGroup { DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "park") }, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(root.overlayRenderer.diagnostics["park"] == .unsupportedSurface)
        #expect(root.overlayRenderer.records["park"]?.entity.isEnabled == false)
    }
    @Test func imageCreditsAreDistinctAndDoNotTriggerTerrainLoad() throws {
        let (_, proxy) = try OverlayRenderFixture.make()
        let store = DioramaStore(configuration: proxy.configuration)
        let bounds = try #require(GeographicBounds(enclosing: OverlayRenderFixture.polygon(proxy).exterior!.coordinates))
        let image = DioramaImageResource(id: "survey", revision: "1", image: try OverlayRenderFixture.image(), attribution: "Survey team")
        let generation = store.loadGeneration
        store.applyContent(DioramaContentGroup {
            DioramaImageOverlay(image: image, bounds: bounds, id: "one")
            DioramaImageOverlay(image: image, bounds: bounds, id: "two").opacity(0.5)
        })
        #expect(store.contentAttribution == "Survey team")
        #expect(store.loadGeneration == generation)
        store.applyContent(nil)
        #expect(store.contentAttribution == nil)
        #expect(store.loadGeneration == generation)
    }

}
