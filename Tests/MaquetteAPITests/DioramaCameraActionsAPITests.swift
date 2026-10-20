import Maquette
import SwiftUI
import Testing

@MainActor
@Suite("Public camera contract")
struct DioramaCameraActionsAPITests {
    @Test func cameraVocabulary() throws {
        let camera = DioramaCamera(heading: .degrees(90), pitch: .degrees(0), distance: 2,
                                   focus: .coordinate(.init(latitude: 37, longitude: -122), altitude: .clampToGround))
        let limits = try #require(DioramaCameraLimits(distance: 0.3...3, pitchDegrees: 0...80))
        #expect(limits.focusPolicy == .insideChunk)
        #expect(DioramaCameraPosition.camera(camera).camera == camera)
        let reader = DioramaReader { proxy in
            Button("Fit") { proxy.fit(.chunk, transition: .easeInOut(duration: 0.3)) }
        }
        _ = reader.dioramaCameraLimits(limits).dioramaCameraTransition(.immediate)
        #expect(EnvironmentValues().dioramaCamera == nil)
    }

    @Test func initialCameraOwnershipOverloads() {
        enum Place: Hashable, Sendable { case summit }
        let region = DioramaRegion(center: Coordinate(latitude: 37, longitude: -122), radius: 1_000)
        let ground = Binding.constant(DioramaGroundPosition(region: region))
        let camera = DioramaCameraPosition.camera(.init(heading: .degrees(45), pitch: .degrees(30), distance: 2))
        let featureSelection = Binding<DioramaFeature.ID?>.constant(nil)
        let typedSelection = Binding<Place?>.constant(nil)
        _ = DioramaView(region: region, shape: .hexagonal, physicalSize: 0.6,
                        interactionModes: .all, initialCamera: camera, selection: featureSelection)
        _ = DioramaView(region: region, initialCamera: camera, selection: typedSelection)
        _ = DioramaView(initialRegion: region, initialCamera: camera, selection: featureSelection)
        _ = DioramaView(initialRegion: region, initialCamera: camera, selection: typedSelection)
        _ = DioramaView(groundPosition: ground, initialCamera: camera, selection: featureSelection)
        _ = DioramaView(groundPosition: ground, initialCamera: camera, selection: typedSelection)
        // Omitting selection and content must still select the untyped overload.
        _ = DioramaView(region: region, initialCamera: .automatic)
        _ = DioramaView(initialRegion: region, initialCamera: camera)
        _ = DioramaView(groundPosition: ground, initialCamera: camera)
    }

    @Test func controlledCameraOwnershipOverloads() {
        enum Place: Hashable, Sendable { case summit }
        let region = DioramaRegion(center: Coordinate(latitude: 37, longitude: -122), radius: 1_000)
        let ground = Binding.constant(DioramaGroundPosition(region: region))
        let camera = Binding.constant(DioramaCameraPosition.camera(.init(pitch: .zero)))
        let featureSelection = Binding<DioramaFeature.ID?>.constant(nil)
        let typedSelection = Binding<Place?>.constant(nil)
        _ = DioramaView(region: region, cameraPosition: camera, selection: featureSelection)
        _ = DioramaView(region: region, cameraPosition: camera, selection: typedSelection)
        _ = DioramaView(initialRegion: region, cameraPosition: camera, selection: featureSelection)
        _ = DioramaView(initialRegion: region, cameraPosition: camera, selection: typedSelection)
        _ = DioramaView(groundPosition: ground, cameraPosition: camera, selection: featureSelection)
        _ = DioramaView(groundPosition: ground, cameraPosition: camera, selection: typedSelection)
        #expect(camera.wrappedValue.camera?.pitch == .zero)
    }

}
