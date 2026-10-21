import CoreLocation
import Maquette
import SwiftUI
import Testing

@Suite("SwiftUI annotation public API")
@MainActor
struct DioramaAnnotationAPITests {
    private struct StatefulLabel: View {
        @State private var expanded = false
        var body: some View {
            Button(expanded ? "Expanded" : "Details") { expanded.toggle() }
        }
    }

    @Test("Native labels compose with content styling, identity, typed tags and collection builders")
    func declarations() {
        let coordinate = Coordinate(latitude: 36, longitude: -112)
        _ = DioramaView(region: DioramaRegion(center: coordinate, radius: 1500), selection: Binding<Int?>.constant(nil)) {
            DioramaAnnotation("Summit", coordinate: coordinate, anchor: .bottom, id: "summit") {
                StatefulLabel()
            }
            .tint(.orange).opacity(0.8).altitudeReference(.clampToGround)
            .annotationOffset(x: 4, y: -8).annotationPriority(10)
            .annotationOcclusion(.terrain).annotationOverlap(.avoid)
            .annotationScale(metersPerPoint: 0.001).tag(42).id("summit")
            ForEach([1, 2], id: \.self) { value in
                DioramaAnnotation("Place \(value)", coordinate: CLLocationCoordinate2D(latitude: 36, longitude: -112)) {
                    Text("Place \(value)")
                }
                .annotationOverlap(.allow).annotationOcclusion(.alwaysVisible)
            }
        }
    }
}
