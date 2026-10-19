import RealityKit
import SwiftUI
import Testing
@testable import Maquette

@Suite("Diorama typed selection")
@MainActor
struct DioramaSelectionTests {
    @MainActor private final class State<Value> {
        var value: Value?
        init(_ value: Value? = nil) { self.value = value }
        var binding: Binding<Value?> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    private enum Place: Hashable, Sendable { case summit, overlook }

    @Test("Tags select application values and tapping a selected item clears the binding")
    func typedToggle() {
        let state = State<Place>()
        let selection = DioramaSelection(state.binding)
        let identity = DioramaMarkerIdentity(annotationID: "render-id", tag: DioramaSelectionTag(Place.summit))
        selection.toggle(identity)
        #expect(state.value == .summit)
        #expect(selection.isSelected(identity))
        selection.toggle(identity)
        #expect(state.value == nil)
    }

    @Test("Untagged String markers retain annotation-ID selection, including punctuation")
    func legacySelection() {
        let state = State<String>()
        let selection = DioramaSelection(state.binding)
        let identity = DioramaMarkerIdentity(annotationID: "lookout#0_with_underscores", tag: nil)
        selection.toggle(identity)
        #expect(state.value == identity.annotationID)
        #expect(selection.isSelected(identity))
    }

    @Test("Tagged String markers select their tag rather than the rendering identifier")
    func stringTags() {
        let state = State<String>()
        let selection = DioramaSelection(state.binding)
        let identity = DioramaMarkerIdentity(annotationID: "entity", tag: DioramaSelectionTag("model"))
        selection.toggle(identity)
        #expect(state.value == "model")
    }

    @Test("Untagged or mismatched tags leave a typed selection untouched")
    func mismatchedTags() {
        let state = State<Place>(.overlook)
        let selection = DioramaSelection(state.binding)
        selection.toggle(DioramaMarkerIdentity(annotationID: "a", tag: nil))
        selection.toggle(DioramaMarkerIdentity(annotationID: "b", tag: DioramaSelectionTag("summit")))
        #expect(state.value == .overlook)
        #expect(DioramaSelectionTag(Int(1)) != DioramaSelectionTag(Int64(1)))
    }

    @Test("Repeated tags and multipart features share selection independently of entity IDs")
    func repeatedTags() {
        let state = State<Place>(.summit)
        let selection = DioramaSelection(state.binding)
        for id in ["feature#0", "feature#1", "different-feature"] {
            #expect(selection.isSelected(DioramaMarkerIdentity(
                annotationID: id, tag: DioramaSelectionTag(Place.summit)
            )))
        }
    }

    @Test("External binding updates are reflected and selection survives absent content")
    func externalUpdates() {
        let state = State<Place>()
        let selection = DioramaSelection(state.binding)
        let identity = DioramaMarkerIdentity(annotationID: "a", tag: DioramaSelectionTag(Place.summit))
        state.value = .summit
        #expect(selection.isSelected(identity))
        state.value = .overlook
        #expect(!selection.isSelected(identity))
        #expect(state.value == .overlook)
    }

    @Test("Tap routing walks structured identity and ignores entity naming conventions")
    func structuredTapRouting() {
        let state = State<Place>()
        let selection = DioramaSelection(state.binding)
        let parent = Entity()
        parent.name = "An arbitrary application name"
        parent.components.set(DioramaMarkerIdentity(
            annotationID: "feature#literal", tag: DioramaSelectionTag(Place.summit)
        ))
        let hit = Entity()
        parent.addChild(hit)
        let store = DioramaStore(configuration: DioramaConfiguration(center: .init(latitude: 36, longitude: -112), radiusMeters: 1500))
        DioramaLiveInputs.handleTap(on: hit, selection: selection, store: store)
        #expect(state.value == .summit)
        DioramaLiveInputs.handleTap(on: hit, selection: nil, store: store)
        #expect(state.value == .summit)
    }

    @Test("Rendered markers retain entity identity on data edits and regain selection after culling")
    func renderedSelectionPersistence() throws {
        let coordinate = Coordinate(latitude: 36, longitude: -112)
        let configuration = DioramaConfiguration(
            center: .init(latitude: 36, longitude: -112), radiusMeters: 1500
        )
        let state = State<Place>(.summit)
        let root = DioramaEntity()
        root.selection = DioramaSelection(state.binding)
        let initial = DioramaContentGroup {
            DioramaMarker("Old title", coordinate: coordinate, id: "stable").tag(Place.summit)
        }
        let proxy = DioramaProxy(configuration: configuration)
        root.applyContent(initial, using: proxy, physicalSize: 0.8)
        let original = try #require(root.markerEntities["stable"])
        #expect(original.scale.x == 1.5)

        let changed = DioramaContentGroup {
            DioramaMarker("New title", coordinate: Coordinate(latitude: 36.001, longitude: -112), id: "stable")
                .tag(Place.summit)
        }
        root.applyContent(changed, using: proxy, physicalSize: 0.8)
        #expect(root.markerEntities["stable"] === original)
        #expect(original.scale.x == 1.5)

        let offChunk = EllipsoidProjection(
            center: configuration.center, radiusMeters: 1500, physicalSize: 0.8,
            panOffset: SIMD2(2, 0)
        )
        root.applyContent(changed, using: DioramaProxy(configuration: configuration, projection: offChunk), physicalSize: 0.8)
        #expect(root.markerEntities.isEmpty)
        #expect(state.value == .summit)
        root.applyContent(changed, using: proxy, physicalSize: 0.8)
        #expect(try #require(root.markerEntities["stable"]).scale.x == 1.5)
    }
}
