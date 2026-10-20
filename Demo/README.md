# Maquette Demo

An iOS/iPadOS, macOS, and visionOS app that renders terrain chunks from live elevation and imagery tiles, used to verify the
chunk pipeline visually — unit tests cover the geometry buffers, but only a running app shows
whether the result actually reads as a slice of the earth.

## Running

The Xcode project is generated from `project.yml`, so it is not checked in:

```bash
cd Demo && xcodegen generate && open MaquetteDemo.xcodeproj
```

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and network
access. Raster presets fetch real Mapzen elevation and ESRI imagery tiles, so the first render takes
a few seconds. Photorealistic presets require the provider credentials described in the main README.

## Presets

Each preset isolates one part of the chunk model:

| Preset | Verifies |
|---|---|
| Canyon | Circular boundary, strata walls, the baseline look |
| Hexagon | Straight-edged non-circular boundary and its corners |
| Plinth | Rounded-rectangle boundary plus an overhanging display base |
| Star | Arbitrary **concave** outline — the hardest clipping case |
| Surface | `wall: .none`, for comparison against a solid chunk |
| Pan | Live terrain panning within a fixed outline |

Canyon and Surface use the same location and camera on purpose: the difference between them is
exactly what the chunk model adds.

## Gestures

| Platform | Pan | Orbit | Ground zoom |
|---|---|---|---|
| iOS/iPadOS | One-finger drag | Two-finger drag | Pinch |
| macOS | Plain drag | Option-drag | Trackpad pinch or scroll wheel |
| visionOS | Drag | Move around the volume | Pinch |

The automatic loading policy provisions a pan margin and respects each preset's explicit nonzero
style margin. Panning stays inside the loaded ground while more tiles arrive; the initial margin
does not impose a permanent geographic limit. With pan disabled or a zero-margin policy, an orbit
view uses plain drag to rotate instead. Zooming out far enough enters the globe transition.

The controls overlay provides a compass, reset, Fit terrain, overhead-view, and camera-cancel
buttons. Custom controls read the host-scoped `dioramaCamera` environment proxy. Fit terrain uses
point padding and a 0.6-second transition; overhead preserves the current focus, heading, and
distance while setting pitch to zero. Cancel stops an active camera action at its current pose.
Orbit and fit controls disable when the host lacks those capabilities, including AR and visionOS.
Reduce Motion makes transitions immediate. These examples do not establish device validation. Reset restores the last preset-requested
ground and orbit. The compass faces north without changing tilt or distance; it is hidden in AR,
visionOS, globe presentation, and camera route-follow mode. AR placement requires physical hardware.

The demo binds `DioramaGroundPosition` independently from `DioramaCameraPosition`: gestures update
the current geographic region, while preset changes issue an absolute ground request and a separate
orbit request through `cameraPosition:`. Camera headings are clockwise from north; pitch is zero
overhead and 90 degrees horizontal, and distance uses scene meters. Marker selection uses an application enum through `.tag`, independently of the pin's
rendering ID. Existing presets retain their style-specific pan margins through the automatic loading
policy.

## Pan diagnostic

From the repository root, explicitly enable the synthetic pan benchmark in Release mode:

```bash
MAQUETTE_RUN_PAN_BENCHMARK=1 swift test -c release --filter PanBenchmark
```

It measures terrain resampling and LowLevelMesh buffer writes over ten steps of a synthetic
65,000-vertex chunk. It requires a working RealityKit graphics context and is skipped in ordinary
test runs. These CPU timings exclude tile fetching, effect passes, SwiftUI updates, and rendering;
they are not full frame times or an automated performance threshold.


The Camera preset starts with terrain relief, canyon walls, and an oblique view so the chunk's
three-dimensional shape is visible. North is cyan, east orange, south pink, and west green.
Choose View from overhead and Face north to check cardinal orientation: cyan appears at the top.
Face east (heading 90) moves orange to the top and cyan to the left while preserving the pitch.
