import Maquette
import SwiftUI
import Testing

@Suite("Diorama ForEach public construction")
struct DioramaForEachAPITests {
    private struct Place: Identifiable, Sendable {
        let id: Int
        let coordinate: Coordinate
    }

    private func collection<Data: RandomAccessCollection, ID: Hashable & Sendable>(
        _ data: Data, id: KeyPath<Data.Element, ID>,
        @DioramaContentBuilder content: @escaping (Data.Element) -> DioramaContentGroup
    ) -> some DioramaContent {
        ForEach(data, id: id, content: content)
    }

    @Test func identifiableKeyPathAndBuilderHelper() {
        let places = [Place(id: 1, coordinate: Coordinate(latitude: 36, longitude: -112))]
        let identified: ForEach<[Place], Int, DioramaForEachContent> = ForEach(places) { place in
            DioramaMarker(coordinate: place.coordinate)
        }
        let keyed: ForEach<[Place], Int, DioramaForEachContent> = ForEach(places, id: \.id) { place in
            DioramaMarker(coordinate: place.coordinate)
        }
        let helper = collection(places, id: \.id) { place in
            DioramaMarker(coordinate: place.coordinate)
            DioramaPolyline(coordinates: [place.coordinate])
        }
        #expect(identified.items.count == 1)
        #expect(keyed.items.count == 1)
        #expect(helper.items.count == 2)
    }
}
