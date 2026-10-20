import MaquetteNext
import SwiftUI

@MainActor
func cannotFillMarkers() {
    _ = DioramaMarker(coordinate: .init(latitude: 36, longitude: -112)).tag("pin").fill(.red)
}
