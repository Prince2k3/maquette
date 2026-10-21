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
