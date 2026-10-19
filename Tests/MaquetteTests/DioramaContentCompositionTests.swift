import CoreLocation
import SwiftUI
import Testing
@testable import Maquette

@Suite struct DioramaContentCompositionTests {
    private let origin = Coordinate(latitude: 36, longitude: -112)

    private struct Reusable: DioramaContent {
        let coordinate: Coordinate
        let showSecond: Bool
        var body: some DioramaContent {
            DioramaMarker("First", coordinate: coordinate)
            if showSecond {
                DioramaPolyline(coordinates: [coordinate, coordinate])
            }
        }
    }

    private struct Legacy: DioramaContent {
        var items: [DioramaContentItem] { [] }
    }

    private struct Place: Identifiable, Sendable {
        let id: Int
        var title: String
        var coordinate: Coordinate
    }

    private func annotations(_ content: some DioramaContent) -> [DioramaAnnotation] {
        content.items.compactMap { item in
            guard case .annotation(let annotation) = item else { return nil }
            return annotation
        }
    }

    @Test func reusableBodiesConditionsAndLegacyConformers() {
        #expect(Reusable(coordinate: origin, showSecond: false).items.count == 1)
        #expect(Reusable(coordinate: origin, showSecond: true).items.count == 2)
        #expect(Legacy().items.isEmpty)
        let group = DioramaContentGroup {
            Reusable(coordinate: origin, showSecond: true)
            if false { DioramaMarker(coordinate: origin) }
            for _ in 0..<2 { DioramaMarker(coordinate: origin) }
        }
        #expect(group.items.count == 4)
    }

    @Test func localStyleBeatsGroupDefaultsAndLastChainWins() throws {
        let content = DioramaContentGroup {
            DioramaMarker(coordinate: origin).tint(.orange).tint(.green)
            DioramaMarker(coordinate: origin)
                .altitudeReference(.absolute)
            DioramaPolyline(coordinates: [origin, origin])
                .stroke(.purple, width: .physicalMeters(0.009))
                .tint(.pink)
        }.tint(.blue).altitudeReference(.relativeToGround)
        let result = annotations(content)
        #expect(result[0].style.tint == .green)
        #expect(result[0].style.altitude == .relativeToGround)
        #expect(result[1].style.tint == .blue)
        #expect(result[1].style.altitude == .absolute)
        #expect(result[2].style.tint == .pink)
        #expect(result[2].style.lineWidth == 0.009)
    }

    @Test func selectionTagPreservesModifierPriority() throws {
        let marker = DioramaMarker(coordinate: origin)
            .tint(.red).tag(7).tint(.blue).altitudeReference(.absolute)
        let annotation = try #require(annotations(marker).first)
        #expect(annotation.style.tint == .blue)
        #expect(annotation.style.altitude == .absolute)
        #expect(annotation.selectionTag?.value(as: Int.self) == 7)
    }

    @Test func modifiersPreserveIdentityAndRoutePreview() throws {
        let marker = DioramaMarker(coordinate: origin, id: "pin")
        let route = DioramaRoutePreview(coordinates: [CLLocationCoordinate2D(latitude: 36, longitude: -112)])
        let content = DioramaContentGroup {
            marker
            route
        }
        let result = content.tint(.orange).altitudeReference(.absolute).items
        guard case .annotation(let annotation) = result[0] else {
            Issue.record("Expected annotation"); return
        }
        #expect(annotation.id == marker.annotation.id)
        #expect(annotation.contentIdentity == annotations(content)[0].contentIdentity)
        #expect(result[1] == .routePreview(route))
    }

    @Test func forEachKeepsIdentityAcrossReordersAndFeatureUpdates() {
        let places = [
            Place(id: 7, title: "A", coordinate: origin),
            Place(id: 9, title: "B", coordinate: origin)
        ]
        func content(_ values: [Place]) -> some DioramaContent {
            DioramaContentGroup {
                ForEach(values) { place in
                    DioramaMarker(place.title, coordinate: place.coordinate)
                    if true { DioramaPolyline(coordinates: [place.coordinate]) }
                }
            }
        }
        let before = annotations(content(places))
        let updated = [
            Place(id: 9, title: "Renamed", coordinate: Coordinate(latitude: 37, longitude: -113)),
            places[0]
        ]
        let after = annotations(content(updated))
        #expect(before[0].contentIdentity == after[2].contentIdentity)
        #expect(before[1].contentIdentity == after[3].contentIdentity)
        #expect(before[2].contentIdentity == after[0].contentIdentity)
        #expect(before[0].contentIdentity != before[1].contentIdentity)
    }

    @Test func optionalChildDoesNotRenumberItsFollowingSibling() {
        func content(showFirst: Bool) -> some DioramaContent {
            ForEach([1], id: \.self) { _ in
                if showFirst { DioramaMarker("Optional", coordinate: origin) }
                DioramaMarker("Stable", coordinate: origin)
            }
        }
        let before = annotations(content(showFirst: true))
        let after = annotations(content(showFirst: false))
        #expect(before[1].contentIdentity == after[0].contentIdentity)
    }

    @Test func supportedForEachElementsAlwaysCarryTypedIdentity() {
        let collection: ForEach<[Int], Int, DioramaForEachContent> = ForEach([1, 2], id: \.self) { _ in
            DioramaMarker(coordinate: origin)
        }
        let elements = collection.data.flatMap { collection.content($0).items }
        let metadata = elements.compactMap { item -> DioramaContentIdentity? in
            guard case .annotation(let annotation) = item else { return nil }
            return annotation.contentIdentity
        }
        #expect(metadata.count == 2)
        #expect(metadata.allSatisfy { identity in
            identity.scopes.contains { scope in
                if case .element = scope { return true }
                return false
            }
        })
        #expect(Set(metadata).count == 2)
    }

    private struct CollidingID: Hashable, Sendable, CustomStringConvertible {
        let value: Int
        func hash(into hasher: inout Hasher) { hasher.combine(0) }
        var description: String { "same-description" }
    }

    @Test func keyPathIDsDoNotStringifyAndSiblingCollectionsAreNamespaced() {
        struct Row: Sendable { let key: CollidingID }
        let rows = [Row(key: CollidingID(value: 1)), Row(key: CollidingID(value: 2))]
        let content = DioramaContentGroup {
            ForEach(rows, id: \.key) { _ in DioramaMarker(coordinate: origin) }
            ForEach(rows, id: \.key) { _ in DioramaMarker(coordinate: origin) }
        }
        let keys = annotations(content).compactMap(\.contentIdentity)
        #expect(keys.count == 4)
        #expect(Set(keys).count == 4)
    }
}
