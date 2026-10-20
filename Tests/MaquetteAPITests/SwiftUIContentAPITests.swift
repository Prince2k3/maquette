import CoreLocation
import MapKit
import Maquette
import SwiftUI
import Testing

@Suite("SwiftUI content public API")
@MainActor
struct SwiftUIContentAPITests {
    private struct Place: Identifiable, Sendable {
        let id: UUID
        let name: String
        let coordinate: Coordinate
    }

    private struct TrailContent: DioramaContent {
        let coordinates: [Coordinate]
        var body: some DioramaContent {
            DioramaPolyline(coordinates: coordinates)
                .stroke(.blue, width: .physicalMeters(0.003))
                .altitudeReference(.clampToGround)
            if let first = coordinates.first {
                DioramaMarker("Start", coordinate: first).tint(.orange)
            }
        }
    }

    @Test("Minimal, custom, GeoJSON, and controlled-camera declarations infer their types")
    func declarations() {
        let coordinate = Coordinate(latitude: 36.0544, longitude: -112.1401)
        let region = DioramaRegion(center: coordinate, radius: 6000)
        _ = DioramaView(region: region)
        _ = DioramaView(region: region) { TrailContent(coordinates: [coordinate, coordinate]) }
        _ = DioramaView(region: region) { Feature.point(coordinate) }
        _ = DioramaView(region: region, cameraPosition: .constant(.camera(DioramaCamera())))
        // MapKit and Maquette vocabulary can coexist in a consumer module.
        _ = MapCameraPosition.automatic
    }

    @Test("A selectable collection accepts UUIDs without string conversion")
    func taggedCollection() {
        let coordinate = Coordinate(latitude: 36, longitude: -112)
        let places = [Place(id: UUID(), name: "Summit", coordinate: coordinate)]
        let selection: Binding<UUID?> = .constant(places[0].id)
        _ = DioramaView(
            region: DioramaRegion(center: coordinate, radius: 1500), selection: selection
        ) {
            ForEach(places) { place in
                DioramaMarker(place.name, coordinate: place.coordinate)
                    .tint(.orange)
                    .tag(place.id)
            }
        }
    }

    @Test("Two dioramas accept independent selection types in one hierarchy")
    func independentViews() {
        let coordinate = Coordinate(latitude: 36, longitude: -112)
        let region = DioramaRegion(center: coordinate, radius: 1500)
        let uuid: Binding<UUID?> = .constant(nil)
        let string: Binding<String?> = .constant(nil)
        _ = HStack {
            DioramaView(region: region, selection: uuid) {
                DioramaMarker(coordinate: coordinate).tag(UUID())
            }
            DioramaView(region: region, selection: string) {
                DioramaMarker(coordinate: coordinate, id: "legacy")
                DioramaMarker(coordinate: coordinate).tag("tagged")
            }
        }
    }
}
