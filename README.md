# Maquette

A Swift package that renders **configurable terrain chunks of the real world** — a slice of the
earth lifted out of the ground and set on a table. Real elevation and satellite imagery on top,
geological strata down the cut sides, a closing face underneath: a solid, not a draped map.

![A snow-covered alpine mountain on a hexagonal terrain chunk with exposed geological layers](assets/maquette-hero.png)

*Generated concept illustration inspired by the Mount Rainier demo.*

- **visionOS** — a volumetric diorama in the room; drag to pan, pinch to zoom the ground.
- **iOS / iPadOS** — an interactive 3D view; one finger slides the terrain, two orbit and pinch.
  Optional AR placement puts the chunk on a real table at its true physical size.
- **macOS** — the same scene under trackpad and mouse: drag pans, option-drag orbits, pinch or
  scroll zooms.

Zoom out far enough — fingers pinching together — and the chunk dissolves into a globe you can
spin; zoom back in to cut a new chunk wherever you left it pointing.

## Quick start

```swift
import Maquette
import SwiftUI

struct CanyonView: View {
    @State private var position: DioramaCameraPosition = .automatic
    @State private var selected: DioramaFeature.ID?

    var body: some View {
        DioramaView(
            region: DioramaRegion(
                center: CLLocationCoordinate2D(latitude: 36.0544, longitude: -112.1401),
                radius: 6000
            ),
            cameraPosition: $position,
            selection: $selected
        ) {
            DioramaMarker("Yavapai Point",
                          coordinate: CLLocationCoordinate2D(latitude: 36.0667, longitude: -112.1170),
                          tint: .orange)
        }
        .dioramaStyle(.standard(exaggeration: 1.6, chunk: .canyon))
        .dioramaLoadingPolicy(.prefetchMargin(0.8))
        .globeTransition()
    }
}
```

The API follows MapKit's SwiftUI shape: the initializer carries *place and interaction*
(`DioramaRegion`, `DioramaInteractionModes`, a `DioramaCameraPosition` binding, a selection
binding), modifiers carry *style and observation* (`.dioramaStyle`, `.dioramaEffect`,
`.onDioramaCameraChange`, `.onDioramaLoadingChange`), and a result builder carries *content*
(`DioramaMarker`, `DioramaPolyline`, bare GeoJSON `Feature`s, or a whole decoded
`FeatureCollection`). The region and style are live — hand the view different ones and the diorama
relocates or rebuilds in place.

For before/after examples and compatibility details, see
[[migrating-to-the-swiftui-api|Migrating to the SwiftUI API]] in the DocC catalog
(`Sources/Maquette/Maquette.docc`).

## Compose and select content

Use a `DioramaContent` body to build reusable content, and SwiftUI `ForEach` to draw your models.
Selection accepts `Hashable & Sendable` values such as UUIDs or enums. A tag identifies the selected
model; the collection ID keeps its rendered marker stable when its title or coordinate changes.

```swift
// places contains Identifiable values with UUID IDs and a coordinate property.
@State private var selectedPlace: UUID?

DioramaView(region: region, selection: $selectedPlace) {
    ForEach(places) { place in
        DioramaMarker(place.name, coordinate: place.coordinate)
            .tint(.orange)
            .tag(place.id)
    }
    DioramaPolyline(coordinates: trail)
        .stroke(.blue, width: .physicalMeters(0.003))
}
```

Existing String selection bindings continue to select untagged markers by annotation ID. Tapping
an already selected marker clears selection; markers sharing a tag select together. Off-chunk or
removed content leaves the application selection intact. Tagged polylines, polygons, circles, and image overlays also participate in typed selection. Polygon holes and clipped-away geometry do not select. iOS/iPadOS/macOS line picking uses an independent 8-point tolerance; visionOS uses a wider spatial target. Shape selection writes the binding; use that value to choose a selected fill or stroke.

Content modifiers also support `.altitudeReference(.relativeToGround)`. Widths use explicit `.physicalMeters` or `.geographicMeters` units. A modifier on a group supplies defaults; modifiers inside its children
win. Existing initializer styling and custom content that implements `items` remain supported.

## Custom SwiftUI annotations

Attach a SwiftUI label or control to a coordinate. Stable `ForEach` IDs preserve each label's local
state as its place moves or the collection changes; use `.tag` for typed selection.

```swift
DioramaView(region: region, selection: $selectedPlace) {
    ForEach(places) { place in
        DioramaAnnotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
            Text(place.name).padding(8).background(.regularMaterial, in: Capsule())
        }
        .annotationOffset(y: -8)
        .annotationPriority(10)
        .tag(place.id)
    }
}
```

Labels project onto the viewport on iOS/iPadOS/macOS and become native physical attachments on
visionOS. See [[CustomAnnotations|Custom SwiftUI annotations]] in the DocC catalog for state,
interactive controls, occlusion, layout budgets, and spatial sizing.

## Geographic overlays

```swift
DioramaView(region: region, selection: $selectedPlace) {
    DioramaPolygon(parkPolygon, id: "park") // Polygon supports exterior + holes
        .fill(.green.opacity(0.2))
        .stroke(.green, style: DioramaStrokeStyle(
            width: .geographicMeters(12), lineCap: .round, lineJoin: .round,
            dash: [80, 40]
        ))
        .tag(parkID)
    DioramaCircle(center: center, radius: 500) // geographic meters
        .fill(.blue.opacity(0.2))
        .stroke(.blue, width: .physicalMeters(0.003))
    DioramaImageOverlay(image: surveyImage, bounds: surveyBounds)
        .opacity(0.6)
}
```

Create `surveyImage` with `DioramaImageResource(id:revision:image:attribution:)` from a decoded
`CGImage`. Increment its revision when its pixels change. Images are north-up, retain their original
UV extent when clipped, and add their credit alongside the terrain provider's credit. Opacity edits
reuse the texture. Dash lengths and phase use the stroke width's unit system.

GeoJSON polygons and `DioramaFeature(feature)` use the same holes-aware rendering path. The old
GeoJSON wrapper names `DioramaAnnotation` and `AnnotationStyle` are now `DioramaFeature` and
`DioramaFeatureStyle`; `DioramaAnnotation` now declares a custom SwiftUI label.

These overlays conform to raster terrain triangles. Ground-relative placement over photorealistic
3D Tiles is unavailable: unsupported overlays are omitted with a diagnostic instead of appearing on
a false flat surface. Absolute-altitude placement remains available. Geometry updates are asynchronous
and pending shapes are hidden until ready. Fill, color, opacity, selection, and image revision changes
update existing resources without fetching terrain; shape, altitude, and stroke geometry changes
rebuild overlay buffers. This does not establish a per-frame overlay performance guarantee.

## Control geographic navigation

Use `initialRegion:` for an initial place, `region:` for live region inputs, or `groundPosition:`
when your app needs to drive and observe geographic navigation. The ground binding owns the center
and absolute radius; the separate `cameraPosition:` binding controls the orbit camera.

```swift
@State private var ground = DioramaGroundPosition(region: canyonRegion)

DioramaView(groundPosition: $ground)
    .dioramaShape(.hexagonal)
    .dioramaPhysicalSize(0.8)
    .onDioramaNavigationChange(frequency: .onEnd) { context in
        saveLastRegion(context.position.region)
    }

// Recenter at the current geographic scale:
ground = DioramaGroundPosition(region: DioramaRegion(
    center: destination, radius: ground.region.radius
))
```

Ground requests rebuild at the requested region. Gestures write the applied center and radius back
without triggering another load. `positionedByUser` identifies gesture read-back, and callbacks also
report phase and origin. The camera in a navigation context is `nil` on visionOS. Globe steering is
reported when the return commits and its chunk arrives.

Panning now works with the default interaction modes. `.dioramaLoadingPolicy(.automatic)` provisions
a margin; `.prefetchMargin(0.8)` tunes it and `.prefetchMargin(0)` keeps a fixed chunk. Existing style
`panRange` arguments still work. Camera observers can use
`.onDioramaCameraChange(frequency: .onEnd)` for terminal updates; the original camera-only closure
remains available.

## Frame and drive the camera

Use `initialCamera: .camera(...)` to seed an orbit once, or `cameraPosition: $camera` to drive it
and receive gesture read-back. These are separate initializer overloads; choose one camera owner.
`DioramaCamera.heading` is a SwiftUI `Angle` clockwise from north. `pitch` is zero overhead and
90 degrees horizontal; `distance` is a `Float` in scene meters. The default focus is `.chunkCenter`.
A `.coordinate(location, altitude: .clampToGround)` focus is resolved through the active projection
and follows ground pan, zoom, and reload.

For repeatable actions, scope a proxy to one diorama:

```swift
DioramaReader { proxy in
    DioramaView(initialRegion: region, initialCamera: .camera(
        DioramaCamera(heading: .degrees(20), pitch: .degrees(55), distance: 1.5)
    ))
    .dioramaControls {
        Button("Fit terrain") {
            proxy.fit(.chunk, padding: EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24),
                      transition: .easeInOut(duration: 0.6))
        }
        .disabled(!proxy.capabilities.canFit)
    }
}
```

`DioramaReader` and its proxy are main-actor scoped; each reader hosts one diorama. Custom controls
inside `.dioramaControls` can instead read the optional `@Environment(\.dioramaCamera)` proxy.
`setCamera`, `fit`, and `reset` are actions: repeating an equal request still runs it. `cancel()`
stops the active action at its current pose. Check `capabilities.canOrbit` and `canFit` before
presenting actions; virtual-camera actions are unavailable in AR and visionOS volumes.

A successful submission returns `.accepted(id)`, a receipt rather than a completion. Observe
`activeRequest`, `lastResult`, or `result(for: id)` for `.completed(id, camera)`, `.cancelled(id)`,
`.requiresGroundNavigation(id)`, `.constrainedFit(id)`, or `.invalidTarget(id)`. Invalid input returns
`.invalidRequest`; an unavailable host returns `.unavailable`.

Fit `.chunk`, `.bounds(geographicBounds)`, or `.contentIDs(["trail"])`. Give content stable string IDs
with `.id("trail")` or a feature/primitive constructor's `id:`; IDs survive styling modifiers.
Fits account for relief and cut walls, viewport aspect, safe areas, and scoped controls. Their
`padding` adds screen points to `.dioramaCameraFitInsets(...)`. A fit never navigates the ground
implicitly; handle `.requiresGroundNavigation` by issuing a separate ground request.

Use `.dioramaCameraLimits(...)` to share distance, pitch, and focus constraints across gestures,
bindings, and proxy actions. `DioramaCameraLimits(distance:pitchDegrees:focusPolicy:)` is failable;
pitch limits are degrees in `0...90`, and focus policy is `.insideChunk` or `.unrestricted`.
`.dioramaCameraTransition(.easeInOut(duration: 0.6))` configures declarative camera transitions;
proxy actions accept their own transition. Motion uses elapsed time, smooth easing, and the shortest
heading arc. Reduce Motion applies requests immediately.

## Configure input and controls

Interaction permissions are independent: `.heading`, `.pitch`, `.groundPan`, `.groundZoom`,
and `.cameraZoom`. The compatibility names remain: `.rotate` enables heading and pitch, `.zoom`
enables both zoom targets, and `.pan` enables ground pan. These permissions govern user input;
application requests remain authoritative.

The default `.map` input preset uses one-finger/plain drag for ground pan, two-finger twist for
heading, two-finger vertical drag for pitch, and pinch for ground zoom. On macOS, Option-drag
orbits; wheel/two-finger scroll zooms the ground, and Shift-wheel zooms the camera. Native macOS
trackpad rotation is not mapped. A ground operation that is unavailable does nothing: it never
silently becomes an orbit or camera zoom. `.legacyOrbit` restores drag/touch orbit mappings and
allows an implicit gesture zoom to dolly when ground zoom is unavailable; explicit zoom targets
always retain their meaning.

```swift
struct TerrainControlsView: View {
    let region: DioramaRegion

    private var input: DioramaInputConfiguration {
        var input = DioramaInputConfiguration.map
        input.zoomSensitivity = 0.8
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

Each control targets its hosting diorama and reflects available operations and limits. Ground zoom
changes the geography in the chunk; camera zoom changes viewing distance. Pitch and perspective
controls require an orbit camera. Fit frames the chunk by default. Reset returns to the last
app-requested geography and orbit, preserving appearance, content, selection, and AR/volume placement;
interaction does not redefine that home. Camera transitions respect Reduce Motion. AR and visionOS
volumes have no virtual-camera controls; ground controls remain available when supported.

Focus the scene for keyboard input: arrows pan; Option-arrows change heading/pitch; `+`/`-` zoom
the ground; Option-`=`/`-` zoom the camera; `N` faces north, `O` looks overhead, `F` fits, and `R`
resets. `DioramaKeyboardHelp` exposes the configured mappings. Annotation editors keep their own
input. On macOS, wheel zoom requires focus and a pointer inside the visible scene, outside controls
and labels. Accepted wheel input is consumed so an enclosing scroll view does not also scroll.
Configure `panSensitivity`, `orbitSensitivity`, and `zoomSensitivity` with positive finite multipliers;
invalid values resolve to 1. Change `wheelZoomTarget`, `alternateWheelModifiers`, or
`keyboardShortcuts` through `.dioramaInput(...)`.

## Own the loading UI

```swift
DioramaView(initialRegion: region)
    .dioramaLoadingOverlay { context in
        if case .loading = context.state {
            ProgressView("Preparing diorama")
        } else if case .failed = context.state {
            Button("Try again") { context.retry() }
        }
    }
```

The custom overlay replaces the default loading, error, and streaming UI. Use
`.dioramaLoadingOverlayHidden()` when loading is displayed elsewhere. Required source attribution
continues to display independently.

## Features

- **Terrain chunks** cut to any outline — circles, polygons, arbitrary concave shapes, or a real
  GeoJSON boundary (`DioramaRegion(fitting:)` + `DioramaShape.geoJSON(_:)` frame and cut a city
  limit or park boundary at true scale).
- **Unbounded panning**: the outline stays put while the world slides beneath it, fetching tiles
  as it goes; **ground zoom** widens the map under the fixed chunk, all the way out to a globe.
- **Photorealistic 3D Tiles** (Google, Cesium ion) clipped to the same outlines, with the required
  per-tile attribution aggregated and displayed automatically.
- **Effects**: hologram contours, inked-illustration, and terraced contour-model treatments, all
  applied over the chunk already in hand.
- **OSM buildings** extruded over the terrain (prototype).
- **GeoJSON-native**: the `Geo` layer speaks RFC 7946 directly and ships Turf-style measurement
  (`Turf.distance`, `bearing`, `destination`, booleans, and more).
- **AR placement** on iOS/iPadOS via `.dioramaARPlacement(_:)` — RealityView-native
  (`SpatialTrackingSession`), no ARView.
- Swift 6 strict concurrency, `@Observable` only, zero dependencies, no bundled resources.

## Platforms

| Platform | Minimum | Notes |
|----------|---------|-------|
| visionOS | 2.0 | Volumetric window; drag pans, pinch zooms the ground |
| iOS / iPadOS | 18.0 | Touch gestures; AR placement |
| macOS | 15.0 | Trackpad/mouse; pinch and scroll-wheel zoom |

The floors are set by `LowLevelMesh`, which is what makes panning a buffer write instead of a
per-frame mesh compile. watchOS has no RealityKit and cannot be supported.

## Data sources and keys

| Source | Key | Default |
|--------|-----|---------|
| ESRI World Imagery | none | imagery default |
| Mapzen Terrarium (AWS) | none | elevation default |
| MapTiler satellite / terrain | API key | `.mapTilerSatellite(apiKey:)` / `.mapTiler(apiKey:)` |
| Google Photorealistic 3D Tiles | API key | `.photorealistic(provider: GoogleTiles3DProvider(apiKey:))` |
| Cesium ion | access token | `CesiumIonTiles3DProvider(accessToken:assetId:)` |

Google bills the **root tileset request only** (~one event per diorama load); the provider caches
the root so preset switches and relaunches stay free. **Attribution**: the library displays the
per-tile source credits automatically, as the services require; Google additionally requires its
logo on screen, which your app must place — see the
[Map Tiles API policies](https://developers.google.com/maps/documentation/tile/policies).

## Demo

`Demo/` contains an iOS demo app (XcodeGen project) with presets covering every feature — chunks,
outlines, photorealistic tiles, panning, effects, buildings, and the globe handoff. See
[Demo/README.md](Demo/README.md).

## License

MIT — see [LICENSE](LICENSE).
