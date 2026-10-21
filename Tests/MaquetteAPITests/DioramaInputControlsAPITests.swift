import Maquette
import SwiftUI
import Testing

@Suite("Diorama navigation controls public API")
@MainActor
struct DioramaInputControlsAPITests {
    @Test("Navigation controls construct safely without a host")
    func controlsWithoutHost() {
        _ = DioramaZoomControls().buttonStyle(.bordered)
        _ = DioramaZoomControls(target: .camera).buttonStyle(.borderedProminent)
        _ = DioramaPitchControl()
        _ = DioramaPerspectiveToggle().buttonStyle(.bordered)
        _ = DioramaFitButton()
        _ = DioramaFitButton(target: .contentIDs(["summit"]), padding: EdgeInsets(
            top: 10, leading: 20, bottom: 30, trailing: 40
        ))
    }

    @Test("Two hosts compose native controls with independently configured inputs")
    func scopedControlsAndInputMapping() {
        let region = DioramaRegion(center: Coordinate(latitude: 36, longitude: -112), radius: 1_000)
        var customInput = DioramaInputConfiguration.map
        customInput.panSensitivity = 1.5
        customInput.orbitSensitivity = 0.75
        customInput.zoomSensitivity = 2
        customInput.wheelZoomTarget = .camera
        customInput.alternateWheelModifiers = .option
        customInput.keyboardShortcuts = [
            DioramaKeyboardShortcut("g", action: .zoom(.ground, steps: 1)),
            DioramaKeyboardShortcut("c", modifiers: .command, action: .zoom(.camera, steps: -1)),
            DioramaKeyboardShortcut("o", action: .overhead),
            DioramaKeyboardShortcut("b", action: .oblique),
            DioramaKeyboardShortcut("f", action: .fit)
        ]
        _ = HStack {
            DioramaView(region: region, interactionModes: [.heading, .pitch, .groundPan, .groundZoom, .cameraZoom])
                .dioramaInput(customInput)
                .dioramaControls(alignment: .bottomTrailing) {
                    VStack {
                        DioramaZoomControls()
                        DioramaZoomControls(target: .camera)
                        DioramaPitchControl()
                        DioramaPerspectiveToggle()
                        DioramaFitButton()
                        DioramaCompass()
                        DioramaResetButton()
                        DioramaKeyboardHelp()
                    }
                    .buttonStyle(.bordered)
                }
            DioramaView(initialRegion: region)
                .dioramaInput(.legacyOrbit)
                .dioramaControls {
                    DioramaZoomControls(target: .ground)
                    DioramaFitButton(target: .contentIDs(["summit"]))
                }
        }
    }
}
