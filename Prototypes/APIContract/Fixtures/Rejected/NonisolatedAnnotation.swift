import MaquetteNext
import SwiftUI

func cannotBuildAnnotationOutsideMainActor() {
    _ = DioramaAnnotation("Label", coordinate: .init(latitude: 36, longitude: -112)) {
        Text("Main actor")
    }
}
