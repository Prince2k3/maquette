import CoreGraphics
import RealityKit
import SwiftUI
import Testing
@testable import Maquette

@Suite("Geographic shape selection")
@MainActor
struct DioramaOverlaySelectionTests {
    private func hit(_ root: DioramaEntity, _ point: SIMD2<Float>) -> DioramaMarkerIdentity? {
        root.overlayRenderer.hitTest(at: CGPoint(x: Double(point.x * 1000), y: Double(point.y * 1000)),
            project: { CGPoint(x: Double($0.x * 1000), y: Double($0.z * 1000)) },
            ray: .init(origin: .init(point.x, 1, point.y), direction: .init(0, -1, 0)))
    }
    @Test func polygonHolesAndUntaggedShapesDoNotSelect() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        root.selection = DioramaSelection(Binding<String?>.constant(nil))
        root.applyContent(DioramaContentGroup {
            DioramaPolygon(OverlayRenderFixture.polygon(proxy, hole: true), id: "park").tag("selected")
        }, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(hit(root, .zero) == nil)
        #expect(hit(root, .init(0.2, 0))?.tag?.value(as: String.self) == "selected")
        #expect(hit(root, .init(0.6, 0)) == nil)
        root.applyContent(DioramaContentGroup { DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "park") }, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(hit(root, .init(0.2, 0)) == nil)
    }
    @Test func thinLineUsesIndependentScreenToleranceAndLaterLayersWinTies() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let anchor = (proxy.projection as! TerrainProjection).anchor
        let coordinates = [-0.2, 0.2].map { anchor.coordinate(forDioramaX: $0, z: 0) }
        root.selection = DioramaSelection(Binding<String?>.constant(nil))
        root.applyContent(DioramaContentGroup {
            DioramaPolyline(coordinates: coordinates, id: "line").stroke(.blue, width: .physicalMeters(0.001)).tag("route")
        }, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(hit(root, .init(0, 0.006))?.tag?.value(as: String.self) == "route")
        #expect(hit(root, .init(0, 0.015)) == nil)
        root.applyContent(DioramaContentGroup {
            DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "back").tag("back")
            DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "front").tag("front")
        }, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(hit(root, .init(0.2, 0))?.tag?.value(as: String.self) == "front")
    }
    @Test func spatialTargetsUseExactMeshesAndDisappearWhenTagsAreRemoved() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        root.selection = DioramaSelection(Binding<String?>.constant(nil))
        root.overlayRenderer.spatialHitTesting = true
        root.applyContent(DioramaContentGroup {
            DioramaPolygon(OverlayRenderFixture.polygon(proxy, hole: true), id: "park").tag("park")
        }, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let record = try #require(root.overlayRenderer.records["park"])
        #expect(record.entity.components[CollisionComponent.self] != nil)
        #expect(hit(root, .zero) == nil)
        root.applyContent(DioramaContentGroup { DioramaPolygon(OverlayRenderFixture.polygon(proxy, hole: true), id: "park") }, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        #expect(record.entity.components[CollisionComponent.self] == nil)
    }
    @Test func uuidSelectionTogglesWithoutChangingRenderingIdentity() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let id = UUID()
        var selected: UUID?
        root.selection = DioramaSelection(Binding(get: { selected }, set: { selected = $0 }))
        root.applyContent(DioramaContentGroup {
            DioramaPolygon(OverlayRenderFixture.polygon(proxy), id: "park").tag(id)
        }, using: proxy, physicalSize: 1)
        await root.overlayRenderer.waitUntilIdle()
        let record = try #require(root.overlayRenderer.records["park"])
        let identity = try #require(hit(root, .init(0.2, 0)))
        let writes = root.overlayRenderer.selectionComponentUpdateCount
        root.selection?.toggle(identity)
        root.overlayRenderer.updateSelection()
        #expect(root.overlayRenderer.selectionComponentUpdateCount == writes + 1)
        root.overlayRenderer.updateSelection()
        #expect(root.overlayRenderer.selectionComponentUpdateCount == writes + 1)
        #expect(selected == id)
        #expect(record.entity.components[DioramaOverlaySelectionState.self]?.isSelected == true)
        root.selection?.toggle(identity)
        root.overlayRenderer.updateSelection()
        #expect(root.overlayRenderer.selectionComponentUpdateCount == writes + 2)
        #expect(record.entity.components[DioramaOverlaySelectionState.self]?.isSelected == false)
        #expect(selected == nil)
        #expect(root.overlayRenderer.records["park"] === record)
    }

}
