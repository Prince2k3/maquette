import MaquetteNext
import SwiftUI

@MainActor
func cannotOwnGroundTwice(_ region: DioramaRegion, _ ground: Binding<DioramaGroundPosition>) {
    _ = DioramaView(initialRegion: region, groundPosition: ground)
}
