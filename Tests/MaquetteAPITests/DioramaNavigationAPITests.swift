import Foundation
import Maquette
import SwiftUI
import Testing

@Suite("Public geographic navigation API")
struct DioramaNavigationAPITests {
    @Test("Ground requests are mutable geographic values with application provenance")
    func groundPositionValue() {
        var position = DioramaGroundPosition(region: DioramaRegion(
            center: Coordinate(latitude: 36, longitude: -112), radius: 6_000
        ))
        #expect(!position.positionedByUser)
        position.region.radius = 12_000
        #expect(position.region.radius == 12_000)
        #expect(position == DioramaGroundPosition(region: position.region))
    }

    @Test("Controlled ground composes with a camera, typed selection, and both callback frequencies")
    @MainActor
    func controlledGroundConstruction() {
        let region = DioramaRegion(center: Coordinate(latitude: 36, longitude: -112), radius: 6_000)
        let markerID = UUID()
        let camera = DioramaCamera(azimuth: .degrees(90), elevation: .degrees(30), distance: 1.4)
        _ = DioramaView(
            groundPosition: .constant(DioramaGroundPosition(region: region)),
            shape: .hexagonal, physicalSize: 0.8, interactionModes: .all,
            position: .constant(.camera(camera)), selection: Binding<UUID?>.constant(markerID)
        ) {
            DioramaMarker("Overlook", coordinate: region.center).tag(markerID)
        }
        .dioramaShape(.hexagonal)
        .dioramaPhysicalSize(0.6)
        .dioramaLoadingPolicy(.prefetchMargin(0.6))
        .onDioramaCameraChange { camera in
            let _: DioramaCamera = camera
        }
        .onDioramaCameraChange(frequency: .continuous) { context in
            let _: DioramaCameraChangeContext = context
            let _: DioramaCamera = context.camera
            let _: DioramaNavigationContext.Phase = context.phase
            let _: DioramaNavigationContext.Origin = context.origin
        }
        .onDioramaCameraChange(frequency: .onEnd) { _ in }
        .onDioramaNavigationChange(frequency: .continuous) { context in
            let _: DioramaGroundPosition = context.position
            let _: DioramaCamera? = context.camera
            let _: DioramaNavigationContext.Phase = context.phase
            let _: DioramaNavigationContext.Origin = context.origin
        }
        .onDioramaNavigationChange(frequency: .onEnd) { _ in }

        _ = DioramaView(groundPosition: .constant(DioramaGroundPosition(region: region))) {}
        _ = DioramaView(initialRegion: region, selection: Binding<UUID?>.constant(markerID)) {
            DioramaMarker("Typed startup", coordinate: region.center).tag(markerID)
        }.dioramaLoadingPolicy(.automatic)
        _ = DioramaView(initialRegion: region, selection: Binding<String?>.constant(nil)) {}
            .onDioramaNavigationChange { _ in }
    }
}
