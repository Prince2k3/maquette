# Getting Started

Put a chunk of the real world on the table, then make it yours.

## A minimal diorama

A ``DioramaRegion`` says where and how much ground; everything else has a sensible default.

```swift
import Maquette

DioramaView(region: DioramaRegion(
    center: CLLocationCoordinate2D(latitude: 46.8523, longitude: -121.7603),
    radius: 9000
))
```

## Cut it to a shape

The outline is exact — concave outlines included — and the cut walls show geological strata.

```swift
DioramaView(region: region, shape: .hexagonal)
    .dioramaStyle(.standard(chunk: .alpine))
```

A real-world boundary frames *and* cuts:

```swift
let park = try JSONDecoder().decode(FeatureCollection.self, from: data)
if let region = DioramaRegion(fitting: park), let shape = DioramaShape.geoJSON(park) {
    DioramaView(region: region, shape: shape) { park }
}
```

## Make it interactive

The default interaction modes let one finger slide the terrain beneath the fixed outline, indefinitely —
tiles roll in as the ground moves. The automatic loading policy provisions a pan margin. Pinching zooms the *map*, not the camera, and
`.globeTransition()` lets a zoom-out dissolve into a spinnable globe.

```swift
DioramaView(region: region, cameraPosition: $cameraPosition)
    .dioramaStyle(.standard(chunk: .canyon))
    .dioramaLoadingPolicy(.prefetchMargin(0.8))
    .globeTransition()
```

## Observe and drive

- `cameraPosition:` is the parallel of `MapCameraPosition` — set it to move the camera, read it back as
  the user orbits (`positionedByUser` says which happened).
- `selection:` receives a tapped marker's `.tag` value, or its annotation ID for an untagged String binding.
- `onDioramaLoadingChange(_:)` reports load phases; the built-in overlay still shows the spinner
  and retry affordance.
- The region, style, and content are all live: hand the view different values and the diorama
  relocates, rebuilds, or re-applies in place.

## Compose application content

A content body uses the same builder as the view. Existing content implementations that expose
`items` remain supported.

```swift
struct TrailContent: DioramaContent {
    let coordinates: [Coordinate]

    var body: some DioramaContent {
        DioramaPolyline(coordinates: coordinates)
            .stroke(.blue, width: .physicalMeters(0.003))
            .altitudeReference(.clampToGround)
        if let start = coordinates.first {
            DioramaMarker("Start", coordinate: start).tint(.orange)
        }
    }
}
```

Use SwiftUI `ForEach` directly inside the diorama builder, with identifiable elements or an explicit
`id:` key path. Its IDs must be `Hashable & Sendable`. Let the builder infer its content type;
Maquette's initializer captures those typed IDs before flattening content. Generic helpers should
also accept an `@DioramaContentBuilder` closure rather than constructing an explicitly typed
`ForEach` with primitive marker content.

```swift
@State private var selectedPlace: UUID?

DioramaView(region: region, selection: $selectedPlace) {
    ForEach(places) { place in
        DioramaMarker(place.name, coordinate: place.coordinate)
            .tint(.orange)
            .tag(place.id)
    }
    TrailContent(coordinates: trail)
}
```

The selection type must match the tag type. A tag controls selection independently of rendering
identity: repeated tags select together, while each collection element still needs a unique ID.
Explicit annotation IDs and collection IDs remain stable through title, coordinate, and style
changes. Anonymous content outside a collection uses a digest of its feature as before.

Tapping the selected marker clears selection. Untagged or mismatched markers do not change a typed
selection; untagged markers still use their annotation IDs with a String binding. Removing an item
or panning it outside the outline preserves selection, so it is selected again when it returns.
Polyline and polygon selection are not supported.

Content-local tint and altitude modifiers override defaults applied to a surrounding group. A later
modifier of the same kind on one content value replaces the earlier one, including when `.tag` is
between them. A width of `.physicalMeters(0.003)` is three millimeters of diorama space, not screen
points or geographic meters. Route preview styling continues to use `RoutePreviewStyle`.

## Choose a navigation owner

| Entry point | Behavior |
| --- | --- |
| `DioramaView(initialRegion:)` | Uses the initial region once; state redraws and later style changes preserve the navigated ground. |
| `DioramaView(region:)` | Accepts live region inputs; center-only changes preserve ground zoom, and substrate changes rebuild. |
| `DioramaView(groundPosition:)` | The binding owns geographic center and absolute radius, with gesture read-back on every platform. |
| `cameraPosition:` | Independently requests an orbit camera; visionOS volumes have no virtual camera. |

```swift
@State private var ground = DioramaGroundPosition(region: initialRegion)
@State private var camera: DioramaCameraPosition = .automatic

DioramaView(groundPosition: $ground, cameraPosition: $camera)
    .dioramaShape(.hexagonal)
    .dioramaPhysicalSize(0.8)
    .onDioramaNavigationChange(frequency: .onEnd) { context in
        // context.position.region is the applied geography.
        // context.camera is nil in a visionOS volume.
    }
    .onDioramaCameraChange(frequency: .continuous) { context in
        // context.camera is the resolved orbit, with phase and origin.
    }
```

Application ground requests rebuild at their absolute geographic radius. To recenter while keeping
the current ground scale, construct a new `DioramaGroundPosition` using the current binding's radius.
Gesture read-back is remembered before the binding is written, so it does not become another load.
Newer requests supersede older fetches and their content callbacks. Controlled terrain uses an
anchor centered on the requested coordinate; legacy live-region terrain retains its mosaic mapping.
Radius read-back is the configured nominal geographic radius multiplied by ground zoom.

Camera observers report `.changing`, then `.ended` or `.cancelled` for the actual gesture or
programmatic action. `.onEnd` receives terminal contexts; it does not use a generic settle timer.
Geographic navigation observers keep their own phase and origin semantics. A gesture that returns
to its previous endpoint still produces an end event. The existing `.onDioramaCameraChange { camera in ... }` overload remains
available. Geographic callbacks describe the chunk during a globe journey and report the new place
after a committed return loads it.

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

## Configure prefetch separately

`.dioramaLoadingPolicy(.automatic)` uses a default margin when pan is enabled. Existing nonzero
style `panRange` values remain respected. Set `.prefetchMargin(0.6)` to choose the prefetch fraction,
or `.prefetchMargin(0)` to retain the fixed-chunk behavior. Interaction modes continue to determine
which gestures are permitted. Shape and physical-size modifiers override initializer values at the
nearest point in the view hierarchy and share the same underlying configuration and reload key.

## Replace loading presentation

```swift
DioramaView(initialRegion: region)
    .dioramaLoadingOverlay { context in
        switch context.state {
        case .loading:
            ProgressView("Preparing diorama")
        case .failed:
            Button("Try again") { context.retry() }
        case .loaded:
            if let progress = context.streamingProgress, progress.isStreaming {
                ProgressView(value: progress.fractionComplete)
            }
        case .idle:
            EmptyView()
        }
    }
```

This replaces loading, error, and streaming overlays together. Retry is scoped to that diorama and
only acts in the failed phase. `.dioramaLoadingOverlayHidden()` suppresses both default and custom
loading presentation; the loading-change observer can reflect state elsewhere. Required attribution
is drawn independently and remains visible.
