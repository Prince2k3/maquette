import Maquette
import SwiftUI
import Testing

@Suite("Diorama controls public API")
@MainActor
struct DioramaControlsAPITests {
    @Test("Controls construct without a host and support ordinary button styling")
    func controlsWithoutHost() {
        _ = DioramaCompass().buttonStyle(.bordered)
        _ = DioramaResetButton().buttonStyle(.borderedProminent)
    }

    @Test("An ancestor controls builder supports custom alignment and multiple dioramas")
    func ancestorControls() {
        let region = DioramaRegion(center: Coordinate(latitude: 36, longitude: -112), radius: 1_000)
        _ = HStack {
            DioramaView(region: region)
            DioramaView(initialRegion: region)
        }
        .dioramaControls(alignment: .bottomTrailing) {
            VStack {
                DioramaCompass()
                DioramaResetButton()
            }
            .buttonStyle(.bordered)
            Text("Terrain controls")
        }
        _ = DioramaView(region: region).dioramaControls {
            DioramaResetButton()
        }
    }
}
