import SwiftUI
import Testing
@testable import Maquette

@Suite("Native annotation placement") @MainActor
struct DioramaAnnotationPlacementTests {
    @Test func activeProjectionAndDatum() throws {
        let (_, proxy) = try OverlayRenderFixture.make()
        let terrain = try #require(proxy.projection as? TerrainProjection)
        let coordinate = terrain.anchor.coordinate(forDioramaX: 0.1, z: -0.1)
        let annotation = DioramaAnnotation("A", coordinate: coordinate) { Text("A") }
        let point = try #require(DioramaAnnotationPlacement.position(for: annotation.annotation, projection: terrain, configuration: proxy.configuration))
        let ground = try #require(terrain.position(for: coordinate))
        #expect(abs(point.y - ground.y - 0.002) < 0.00001)
        #expect(abs(point.x - 0.1) < 0.00001)
        var panned = terrain
        panned.panOffset = SIMD2(0.05, 0.02)
        let moved = try #require(DioramaAnnotationPlacement.position(for: annotation.annotation, projection: panned, configuration: proxy.configuration))
        #expect(abs(moved.x - 0.05) < 0.00001)
        #expect(abs(moved.z + 0.12) < 0.00001)
    }
    @Test func outsideAndUnsupportedSurfaceAreOmitted() throws {
        let (_, proxy) = try OverlayRenderFixture.make()
        let outside = DioramaAnnotation("Outside", coordinate: Coordinate(latitude: 0, longitude: 0)) { Text("A") }
        #expect(DioramaAnnotationPlacement.position(for: outside.annotation, projection: proxy.projection, configuration: proxy.configuration) == nil)
        let coordinate = Coordinate(proxy.configuration.center)
        let label = DioramaAnnotation("A", coordinate: coordinate) { Text("A") }
        let photo = EllipsoidProjection(center: proxy.configuration.center, radiusMeters: 1000, physicalSize: 1)
        #expect(DioramaAnnotationPlacement.position(for: label.annotation, projection: photo, configuration: proxy.configuration) == nil)
        var absolute = label.annotation
        absolute.style.altitude = .absolute
        #expect(DioramaAnnotationPlacement.position(for: absolute, projection: photo, configuration: proxy.configuration) != nil)
    }
    @Test func labelDoesNotAlsoRenderAPinAndRegistryExistsBeforeLoad() async throws {
        let (root, proxy) = try OverlayRenderFixture.make()
        let group = DioramaContentGroup {
            DioramaAnnotation("A", coordinate: Coordinate(proxy.configuration.center), id: "label") { Text("A") }
        }
        root.applyContent(group, using: proxy, physicalSize: 1)
        #expect(root.overlayRenderer.records["label"] == nil)
        #expect(root.findEntity(named: "Marker_label") == nil)
        let store = DioramaStore(configuration: proxy.configuration)
        store.applyContent(group)
        let record = try #require(store.annotationRegistry.records["label"])
        store.applyContent(group)
        #expect(store.annotationRegistry.records["label"] === record)
        store.applyContent(nil)
        #expect(store.annotationRegistry.records.isEmpty)
    }
}
