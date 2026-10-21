import Maquette
import SwiftUI
@MainActor
func legacyCameraBinding() {
    _ = DioramaView(region: .init(center: .init(latitude: 36, longitude: -112), radius: 1_000),
                    position: Binding.constant(DioramaCameraPosition.automatic))
}
