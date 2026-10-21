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
| iOS/iPadOS | One-finger drag | Two-finger twist for heading; vertical two-finger movement for pitch | Pinch |
| macOS | Plain drag | Option-drag | Trackpad pinch or scroll wheel |
| visionOS | Drag | Move around the volume | Pinch |

The automatic loading policy provisions a pan margin and respects each preset's explicit nonzero
style margin. Panning stays inside the loaded ground while more tiles arrive; the initial margin
does not impose a permanent geographic limit. With the default `.map` input preset, disabled or unavailable ground pan does not become orbit.
The explicit `.legacyOrbit` preset retains that fallback. Zooming out far enough enters the globe transition.

The controls overlay provides compass, reset, ground/camera zoom, pitch, perspective, fit, keyboard
help, and camera-cancel controls. Custom controls read the host-scoped `dioramaCamera` environment proxy. Fit terrain uses
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
Choose Overhead and Face north to check cardinal orientation: cyan appears at the top.
Face east (heading 90) moves orange to the top and cyan to the left while preserving the pitch.


## Release validation

The Inputs preset places independently focused scenes inside a parent scroll view, with editable
labels. Check that scene zoom consumes its wheel event, wheel over an editor scrolls the parent,
and keyboard commands affect only the focused scene. The Camera preset starts oblique; use its
perspective, pitch, fit, cancel, and reset controls to inspect camera actions.

City, Trail, and Pan 3D exercise visible-mesh placement for pins, labels, lines, polygons, circles,
and north-up image overlays while LOD changes. Provider credentials and network access are needed
for those presets; missing coverage can hide ground-dependent content.

Before release, record hardware touch, AR, and visionOS hand checks separately from macOS rendered
checks and compiler builds. Building the app is not hardware validation. See
[[release-notes-map-content-camera]] and [[map-content-camera-api-plan]] for release scope and evidence.


The Performance preset supplies a reproducible rendered content workload for profiling labels,
paths, polygons, and image overlays. Record the workload settings together with frame/GPU traces
and a long pan/zoom memory capture on target hardware. The opt-in synthetic content harness is:

```sh
MAQUETTE_RUN_CONTENT_BENCHMARK=1 swift test -c release --filter MapContentBenchmark
```

It measures preparation and RSS observations, checks resource identity, and exercises repeated pan
cycles. It does not establish rendered frame time, GPU time, or long-run memory acceptance. Use
`Scripts/validate-demo.sh` to generate and compile the complete demo for each supported platform;
CI builds with an empty credential template and never runs live provider requests.
