import MaquetteNext
import SwiftUI

@MainActor
func cannotOwnCameraTwice(_ region: DioramaRegion, _ camera: Binding<DioramaCameraPosition>) {
    _ = DioramaView(initialRegion: region, initialCamera: .automatic, cameraPosition: camera)
}
