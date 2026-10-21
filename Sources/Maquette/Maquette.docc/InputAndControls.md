# Input and Controls

Choose independent navigation permissions with ``DioramaInteractionModes``, map gestures and keys
with ``DioramaInputConfiguration``, and place native controls beside the scene.

## Separate permissions from mappings

The `interactionModes:` initializer argument accepts five independent permissions:

| Permission | User operation |
| --- | --- |
| `.heading` | Turn the orbit heading |
| `.pitch` | Tilt the orbit camera |
| `.groundPan` | Move geography through the chunk |
| `.groundZoom` | Change how much geography the chunk contains |
| `.cameraZoom` | Move the orbit camera closer or farther away |

`.all` enables all five. Compatibility names are unions: `.rotate` is `[.heading, .pitch]`,
`.zoom` is `[.groundZoom, .cameraZoom]`, and `.pan` is `.groundPan`. Permissions constrain user
input and built-in controls; application-owned ground and camera requests remain authoritative.
An enabled permission still requires the loaded presentation to support that operation.

## Use map gestures by default

The default input configuration is `.map`:

| Platform | Input | Operation |
| --- | --- | --- |
| iOS / iPadOS | One-finger drag | Ground pan |
| iOS / iPadOS | Two-finger twist | Heading |
| iOS / iPadOS | Two-finger vertical drag | Pitch |
| iOS / iPadOS | Pinch | Ground zoom |
| macOS | Plain drag | Ground pan |
| macOS | Option-drag | Heading and pitch |
| macOS | Trackpad pinch | Ground zoom |
| macOS | Wheel / two-finger scroll | Ground zoom |
| macOS | Shift-wheel / Shift-scroll | Camera zoom |

Touch tracking matches fingers by stable identity. Adding, removing, or replacing a finger
re-anchors the gesture instead of introducing a jump. Translation, twist, and pinch cross small
independent recognition thresholds; twist, vertical motion, and pinch can then act simultaneously.
Disabling heading does not disable pitch or pinch. Native macOS trackpad rotation is not mapped;
use Option-drag for heading and pitch.

A map gesture with unavailable ground navigation does nothing. A fixed chunk does not turn a pan
into orbit, and unsupported ground zoom does not move the camera. Use `.dioramaInput(.legacyOrbit)`
for the earlier behavior: primary drag pans when possible and otherwise orbits, while two-finger
drag orbits on touch devices. Its implicit pinch zoom may choose camera dolly when ground zoom is
unavailable. Explicit `.ground` requests, including wheel mappings, keyboard commands, and zoom
buttons, never fall back to `.camera`, even in the legacy preset.

## Configure sensitivity and shortcuts

The configuration applies to each diorama in its view hierarchy. Pan, orbit, and zoom sensitivity
are positive finite multipliers capped at 100; a zero, negative, or nonfinite value resolves to 1. `wheelZoomTarget`
chooses the default wheel operation. Holding `alternateWheelModifiers` chooses the other target;
an empty modifier set disables the alternate mapping.

```swift
import Maquette
import SwiftUI

struct InputExample: View {
    let region: DioramaRegion

    private var input: DioramaInputConfiguration {
        var input = DioramaInputConfiguration.map
        input.panSensitivity = 0.9
        input.orbitSensitivity = 0.8
        input.zoomSensitivity = 0.8
        input.wheelZoomTarget = .ground
        input.alternateWheelModifiers = .shift
        input.keyboardShortcuts.append(
            DioramaKeyboardShortcut("b", action: .oblique)
        )
        return input
    }

    var body: some View {
        DioramaView(initialRegion: region,
                    interactionModes: [.heading, .pitch, .groundPan, .groundZoom, .cameraZoom])
            .dioramaInput(input)
            .dioramaControls(alignment: .topLeading) {
                VStack {
                    DioramaCompass()
                    DioramaZoomControls(target: .ground)
                    DioramaZoomControls(target: .camera)
                    DioramaPitchControl()
                    DioramaPerspectiveToggle()
                    DioramaFitButton()
                    DioramaResetButton()
                    DioramaKeyboardHelp()
                }
                .buttonStyle(.bordered)
            }
    }
}
```

Keyboard mappings apply only while that diorama's scene has keyboard focus. Focus the scene by
selecting it or using keyboard focus navigation. The standard mappings are:

| Key | Action |
| --- | --- |
| Arrow keys | Ground pan |
| Option-left / Option-right | Heading |
| Option-up / Option-down | Pitch |
| `+` or `=`, `-` | Ground zoom in, out |
| Option-`=`, Option-`-` | Camera zoom in, out |
| `N` | Face north |
| `O` | Overhead view |
| `F` | Fit chunk |
| `R` | Reset |

``DioramaKeyboardShortcut`` maps a key and modifiers to a ``DioramaInputAction``. Append mappings
to retain the defaults, or replace `keyboardShortcuts` to supply your own set. The first matching
mapping wins. ``DioramaKeyboardHelp`` presents the host's configured mappings.

Text fields and other controls inside annotations own their input. Scene shortcuts do not act as
application-wide commands. On macOS, wheel navigation also requires the key window, scene focus,
and a pointer inside the clipped visible scene, outside labels and controls. An accepted zoom
consumes the wheel event so an enclosing scroll view does not also scroll. A scene owns momentum
only after accepting that wheel sequence; unavailable input remains available to the surrounding UI.

## Add scoped native controls

Place controls inside `.dioramaControls(alignment:content:)`. Each builder receives its own host;
controls outside the builder have no diorama target. Choose layout, label style, and button style
with ordinary SwiftUI modifiers. Control insets contribute to camera fitting.

- ``DioramaZoomControls`` defaults to ground zoom. Pass `target: .camera` for viewing distance.
  Each direction disables separately at its limit.
- ``DioramaPitchControl`` supplies a native slider within the configured pitch limits.
- ``DioramaPerspectiveToggle`` switches between overhead and oblique views when permitted.
- ``DioramaCompass`` faces north while preserving tilt and distance.
- ``DioramaFitButton`` frames the chunk by default, or an explicit fit target and padding.
- ``DioramaResetButton`` restores the last application-requested geography and orbit. Gestures and
  control actions do not redefine home. Appearance, content, selection, and physical placement remain.

Camera control transitions use the camera transition driver and respect Reduce Motion. Camera
operations are unavailable in AR and visionOS volumes, where the user supplies the viewpoint.
Ground controls continue to work when the active presentation supports them; reset preserves AR
and volume placement. Compass also hides during globe presentation and route-follow mode.

For application-driven camera actions and fitting, use ``DioramaReader`` and
``DioramaCameraProxy``. See <doc:CustomAnnotations> for interactive labels and
<doc:GlobeHandoff> for navigation between a chunk and the globe.
