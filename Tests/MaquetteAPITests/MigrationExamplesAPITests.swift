import Maquette
import SwiftUI
import Testing

// migration-example: compatibility
@MainActor
struct MigrationCompatibilityExample: View {
    let point = Coordinate(latitude: 36, longitude: -112)
    @State private var selected: String?

    var body: some View {
        DioramaView(region: .init(center: point, radius: 1_000), selection: $selected) {
            DioramaMarker("Overlook", coordinate: point, tint: .orange, id: "overlook")
            LegacyMigrationContent(point: point)
        }
        .dioramaInput(.legacyOrbit)
        .dioramaLoadingPolicy(.prefetchMargin(0))
    }
}

struct LegacyMigrationContent: DioramaContent {
    let point: Coordinate
    var items: [DioramaContentItem] {
        DioramaPolyline(coordinates: [point, .init(latitude: 36.01, longitude: -112)]).items
    }
}
// /migration-example

// migration-example: coordinated
@MainActor
struct MigrationCoordinatedExample: View {
    enum Selection: Hashable, Sendable { case overlook, trail, park, radius }
    let point = Coordinate(latitude: 36, longitude: -112)
    @State private var ground = DioramaGroundPosition(region: .init(
        center: .init(latitude: 36, longitude: -112), radius: 1_000))
    @State private var camera: DioramaCameraPosition = .camera(.init(
        heading: .degrees(30), pitch: .degrees(50), distance: 1.6))
    @State private var selection: Selection?

    var body: some View {
        DioramaReader { proxy in
            DioramaView(groundPosition: $ground, cameraPosition: $camera, selection: $selection) {
                DioramaAnnotation("Overlook", coordinate: point, anchor: .bottom, id: "overlook") {
                    Text("Overlook").padding(6).background(.regularMaterial)
                }
                .annotationOcclusion(.terrain).annotationOverlap(.avoid).tag(Selection.overlook)
                DioramaPolyline(coordinates: [point, .init(latitude: 36.01, longitude: -112)])
                    .stroke(.orange, style: .init(width: .geographicMeters(5), lineCap: .round,
                                                  lineJoin: .round, dash: [20, 10]))
                    .id("trail").tag(Selection.trail)
                DioramaPolygon(Polygon(exterior: LinearRing([
                    point, .init(latitude: 36.01, longitude: -112),
                    .init(latitude: 36, longitude: -111.99)
                ])), id: "park")
                    .fill(.green.opacity(0.2)).stroke(.green, width: .physicalMeters(0.002))
                    .tag(Selection.park)
                DioramaCircle(center: point, radius: 200, id: "radius")
                    .fill(.cyan.opacity(0.2)).tag(Selection.radius)
                DioramaFeature(Feature(geometry: .point(Point(point))), style: DioramaFeatureStyle(), id: "survey")
            }
            .dioramaInput(.map)
            .dioramaCameraTransition(.easeInOut(duration: 0.6))
            .dioramaControls {
                VStack {
                    DioramaZoomControls(target: .ground)
                    DioramaZoomControls(target: .camera)
                    DioramaPitchControl()
                    DioramaPerspectiveToggle()
                    DioramaFitButton(target: .contentIDs(["trail"]))
                    DioramaResetButton()
                    Button("Cancel") { proxy.cancel() }
                }
            }
        }
    }
}
// /migration-example

@Suite("Published migration examples")
@MainActor
struct MigrationExamplesAPITests {
    @Test func examplesConstructWithoutFetching() {
        _ = MigrationCompatibilityExample().body
        _ = MigrationCoordinatedExample().body
    }
}
