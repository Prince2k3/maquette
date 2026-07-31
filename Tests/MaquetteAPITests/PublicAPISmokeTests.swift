import CoreLocation
import Maquette
import SwiftUI
import Testing

/// Compiles representative public-API usage with a plain `import Maquette`.
///
/// Every other test file in the package is `@testable`, which reaches internals freely and so
/// proves nothing about what a consumer can see. This target is the consumer: if a demotion or a
/// rename breaks the public surface, it breaks here, at build time, rather than in the first
/// project that depends on the package.
@Suite("Public API Smoke Tests")
struct PublicAPISmokeTests {
    private static let canyon = CLLocationCoordinate2D(latitude: 36.0544, longitude: -112.1401)

    @Test("The view builds from the public vocabulary")
    @MainActor
    func viewBuilds() {
        let region = DioramaRegion(center: Self.canyon, radius: 6000)

        // The full initializer, every parameter spelled out.
        let view = DioramaView(
            region: region,
            shape: .hexagonal,
            physicalSize: 0.8,
            interactionModes: [.rotate, .zoom],
            position: .constant(.automatic),
            selection: .constant(nil)
        ) {
            DioramaMarker("Yavapai Point", coordinate: Self.canyon, tint: .orange, id: "yavapai")
            DioramaPolyline(coordinates: [Self.canyon, Self.canyon], tint: .blue)
            if true {
                DioramaAnnotation(Feature.point(Coordinate(Self.canyon)))
            }
            for index in 0..<2 {
                DioramaMarker("Pin \(index)", coordinate: Self.canyon)
            }
        }

        // The modifier surface.
        _ = view
            .dioramaStyle(.standard(
                elevation: .realistic,
                exaggeration: 1.6,
                imagery: .esriSatellite,
                elevationSource: .mapzen,
                chunk: .canyon,
                buildings: BuildingStyle(exaggeration: 1.5),
                panRange: 0.8
            ))
            .dioramaEffect(.ink)
            .globeTransition()
            .onDioramaCameraChange { _ in }
            .onDioramaLoadingChange { _ in }
            .routePreviewController(RoutePreviewController())
    }

    @Test("A region frames from GeoJSON and the camera value round-trips")
    func regionAndCamera() throws {
        let ring = LinearRing([
            Coordinate(longitude: -112.14, latitude: 36.09),
            Coordinate(longitude: -112.08, latitude: 36.09),
            Coordinate(longitude: -112.08, latitude: 36.13),
            Coordinate(longitude: -112.14, latitude: 36.13),
        ])
        let outline = Geometry.polygon(Polygon(exterior: ring))
        let region = try #require(DioramaRegion(fitting: outline))
        #expect(region.radius > 0)
        #expect(DioramaShape.geoJSON(outline) != nil)

        let camera = DioramaCamera(azimuth: .degrees(90), elevation: .degrees(30), distance: 1.4)
        let position = DioramaCameraPosition.camera(camera)
        #expect(position.camera == camera)
        #expect(!position.positionedByUser)
        #expect(DioramaCameraPosition.automatic.camera == nil)
    }

    @Test("The photorealistic style builds against the provider protocol")
    func photorealisticStyle() {
        struct StubProvider: Tiles3DProvider {
            func fetchTileset() async throws -> Data { Data() }
            func fetchTileContent(uri: String) async throws -> Data { Data() }
            var attribution: String { "Stub" }
        }
        let style = DioramaStyle.photorealistic(provider: StubProvider(), style: .standard)
        #expect(style == style)
        #expect(style != .standard)
    }

    @Test("GeoJSON decodes into content")
    func geoJSONIsContent() throws {
        let json = """
        {"type": "FeatureCollection", "features": [
            {"type": "Feature", "id": "a", "geometry": {"type": "Point", "coordinates": [-112.0, 36.0]}, "properties": null}
        ]}
        """
        let collection = try JSONDecoder().decode(FeatureCollection.self, from: Data(json.utf8))
        #expect(collection.items.count == 1)
        #expect(Turf.distance(
            from: Coordinate(latitude: 36, longitude: -112),
            to: Coordinate(latitude: 36, longitude: -111)
        ) > 0)
    }
}
