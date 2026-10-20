import SwiftUI
import Testing
@testable import Maquette

@Suite("Collection rendering identity")
struct DioramaContentIdentityResolverTests {
    private struct Place: Identifiable, Sendable {
        let id: Int
        var name: String
    }
    private let origin = Coordinate(latitude: 36, longitude: -112)

    private func content(_ places: [Place]) -> DioramaContentGroup {
        DioramaContentGroup {
            ForEach(places) { place in
                DioramaMarker(place.name, coordinate: origin).tag(place.id)
            }
        }
    }

    private func annotations(_ group: DioramaContentGroup) -> [DioramaFeature] {
        group.items.compactMap {
            guard case .annotation(let annotation) = $0 else { return nil }
            return annotation
        }
    }

    @Test("Renderer keys survive reorder and changed feature data without stringifying model IDs")
    func stableRenderingKeys() {
        var resolver = DioramaContentIdentityResolver()
        let before = annotations(resolver.resolve(content([
            Place(id: 1, name: "A"), Place(id: 2, name: "B")
        ])))
        let after = annotations(resolver.resolve(content([
            Place(id: 2, name: "Renamed B"), Place(id: 1, name: "A")
        ])))
        #expect(before[0].id == after[1].id)
        #expect(before[1].id == after[0].id)
        #expect(after[0].selectionTag?.value(as: Int.self) == 2)
        #expect(after[0].feature[property: "title"] == .string("Renamed B"))
        #expect(resolver.identifiers.count == 2)
    }

    @Test("Removed collection identities are released and explicit annotation IDs are preserved")
    func boundedLifetimeAndExplicitIDs() {
        var resolver = DioramaContentIdentityResolver()
        _ = resolver.resolve(content([Place(id: 1, name: "A"), Place(id: 2, name: "B")]))
        _ = resolver.resolve(content([Place(id: 1, name: "A")]))
        #expect(resolver.identifiers.count == 1)
        let group = DioramaContentGroup { DioramaMarker(coordinate: origin, id: "explicit#id") }
        #expect(annotations(resolver.resolve(group))[0].id == "explicit#id")
        #expect(resolver.identifiers.isEmpty)
    }

    @Test("A caller-supplied ID cannot shadow an existing generated collection key")
    func explicitIDCollision() {
        var resolver = DioramaContentIdentityResolver()
        let places = [Place(id: 1, name: "A")]
        let generatedID = annotations(resolver.resolve(content(places)))[0].id
        let group = DioramaContentGroup {
            ForEach(places) { place in DioramaMarker(place.name, coordinate: origin).tag(place.id) }
            DioramaMarker(coordinate: origin, id: generatedID)
        }
        let result = annotations(resolver.resolve(group))
        #expect(result[0].id != generatedID)
        #expect(result[1].id == generatedID)
    }

    @Test("Duplicate collection IDs are diagnosed and diagnostics clear when the input is fixed")
    func duplicateIDs() {
        var resolver = DioramaContentIdentityResolver()
        _ = resolver.resolve(content([Place(id: 1, name: "A"), Place(id: 1, name: "B")]))
        #expect(resolver.duplicateIdentifiers.count == 1)
        _ = resolver.resolve(content([Place(id: 1, name: "A"), Place(id: 2, name: "B")]))
        #expect(resolver.duplicateIdentifiers.isEmpty)
    }
}
