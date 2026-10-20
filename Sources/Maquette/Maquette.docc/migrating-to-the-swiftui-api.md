# Migrating to the SwiftUI API

<!-- Vault metadata (DocC requires the heading first).
---
title: Migrating to the SwiftUI API
tags: [maquette, migration, swiftui]
created: 2026-10-18
updated: 2026-10-20
status: active
type: permanent
---
-->

Adopt composable content, typed selection, geographic navigation, and presentation modifiers
incrementally. Existing String selection, items-only content, initializer styling, and camera-only
callbacks remain supported. The default pan policy and custom-provider comparison need particular
attention when preserving an existing application's behavior.

Vault context: [[README]] and [[mapkit-swiftui-api-plan]]. For package documentation, start with
<doc:GettingStarted> and <doc:Providers>.

## Translate MapKit concepts

| MapKit SwiftUI concept | Maquette equivalent | Meaning in Maquette |
|---|---|---|
| `Map(initialPosition:)` | `DioramaView(initialRegion:)` | Initial geography; subsequent navigation belongs to the diorama. |
| `Map(position:)` | `DioramaView(groundPosition:)` | App-controlled geographic center and absolute radius. |
| `MapCameraPosition` | `DioramaCameraPosition` with `cameraPosition:` | Orbit around the physical chunk; geography is a separate ground binding. |
| `Marker`, `MapPolyline`, `MapContent` | `DioramaMarker`, `DioramaPolyline`, `DioramaContent` | Content in a builder, including reusable `body` declarations. |
| `ForEach` and `.tag` | `ForEach` and `.tag` | Stable collection identity and typed selection have separate jobs. |
| `.mapStyle` | `.dioramaStyle` | Changes the substrate and can reload it. |
| `.mapControls` and `MapCompass` | `.dioramaControls` and `DioramaCompass` | Controls target the diorama hosting their overlay. |
| `.onMapCameraChange` | `.onDioramaNavigationChange` / `.onDioramaCameraChange` | Observe ground geography or orbit, with a requested frequency. |

Maquette renders a solid with a fixed outline. Geographic radius, physical size, and orbit-camera
distance therefore represent three different quantities.

## Move String selection to model tags

Previously, an explicit annotation ID could serve as selection:

```swift
@State private var selected: String?

DioramaView(region: region, selection: $selected) {
    DioramaMarker("Overlook", coordinate: overlook, id: "overlook")
}
```

That remains valid. To select application models directly, bind an optional `Hashable & Sendable`
value and attach a tag of the same type:

```swift
@State private var selectedPlace: UUID?

DioramaView(region: region, selection: $selectedPlace) {
    ForEach(places) { place in
        DioramaMarker(place.name, coordinate: place.coordinate)
            .tag(place.id) // Place.ID is UUID.
    }
}
```

`ForEach` uses each model's typed ID to preserve rendered identity when a title or coordinate
changes. `.tag` chooses the value written to selection. A tag does not replace a collection ID;
avoid indices or newly generated UUIDs when the model has a persistent identity. `ForEach(places,
id: \.id)` is also supported. Use it inside a diorama builder, or annotate a reusable element
closure with `@DioramaContentBuilder`; a `ForEach` specialized to ordinary SwiftUI view content
does not become diorama content automatically.

Tapping the selected marker clears selection. Markers sharing a tag select together. Removing a
marker, panning it off the chunk, or changing its tag does not clear the application's selection.
Untagged markers remain selectable by annotation ID with String bindings. Polylines are not
selection targets.

## Replace flattened items with a content body

An existing custom conformer can continue to expose renderer items:

```swift
struct OverlookContent: DioramaContent {
    let overlook: Coordinate

    var items: [DioramaContentItem] {
        DioramaMarker("Overlook", coordinate: overlook).items
    }
}
```

New reusable content can compose its body instead:

```swift
struct OverlookContent: DioramaContent {
    let overlook: Coordinate
    let trail: [Coordinate]

    var body: some DioramaContent {
        DioramaMarker("Overlook", coordinate: overlook)
            .tint(.orange)
        DioramaPolyline(coordinates: trail)
            .stroke(.blue, width: .physicalMeters(0.003))
    }
}
```

The protocol supplies `items` from the body. Items-only conformers keep their default `Body ==
Never`; migrate them when composition makes their implementation clearer.

## Choose who owns geography

Rename the old `position:` camera argument to `cameraPosition:`. It still means orbit-camera position. It does not recenter the terrain. Select the
initializer that matches your geographic ownership:

| Initializer | Ownership and subsequent changes |
|---|---|
| `initialRegion:` | Captures the initial region for the view's identity. Later input changes do not reset user navigation. |
| `region:` | Live application input. A changed center relocates the terrain while preserving its current ground scale; other substrate changes can rebuild it. |
| `groundPosition:` | A two-way geographic binding. App requests specify an absolute region; gestures write applied center and radius back. |

For app-controlled recentering, replace a changing `region:` input with a ground binding:

```swift
@State private var ground = DioramaGroundPosition(region: canyonRegion)
@State private var orbit: DioramaCameraPosition = .automatic

DioramaView(groundPosition: $ground, cameraPosition: $orbit)
    .onDioramaNavigationChange(frequency: .onEnd) { context in
        saveRegion(context.position.region)
    }

// Recenter without changing the currently shown geographic radius.
ground = DioramaGroundPosition(region: DioramaRegion(
    center: destination, radius: ground.region.radius
))
```

App ground requests rebuild at their requested radius. Gesture read-back avoids another reload.
`positionedByUser` marks interaction read-back; construct a fresh `DioramaGroundPosition(region:)`
for an app request. Navigation contexts include phase and origin. During a globe journey, ground
observations describe the chunk; steering is reported after return commits and its chunk loads.

## Preserve or enable pan behavior

The default `.automatic` loading policy provisions a prefetch margin when `.pan` is enabled. Thus
the default interaction modes now allow terrain panning without setting a style's `panRange`.
To preserve an older fixed chunk, add:

```swift
.dioramaLoadingPolicy(.prefetchMargin(0))
```

To tune loading independently of appearance, use `.prefetchMargin(0.8)`. It describes extra ground
kept ready as a fraction of chunk extent, rather than a geographic pan limit. Positive legacy
style `panRange` values still supply the automatic policy's margin. An explicit loading policy
overrides that legacy value. Zero disables ground panning; remove `.pan` from `interactionModes`
when the intent is to disable the interaction itself.

## Keep reloads separate from effects

Use `.dioramaStyle` for elevation, imagery, providers, chunk construction, or buildings. Substrate
changes can fetch data and rebuild the terrain. Use `.dioramaEffect(.ink)` or another effect to
restyle the chunk already loaded. Effect changes still perform rendering work, but do not request
a new substrate. Content changes are applied in place; buildings visibility can toggle without
refetching the substrate.

## Migrate camera values and actions

Replace camera azimuth/elevation values with `heading` and `pitch`, both SwiftUI `Angle` values.
The equivalent pose is `heading = -oldAzimuth` and `pitch = .radians(.pi / 2 - oldElevation)`.
Heading is clockwise from north; pitch measures from overhead (0 degrees) toward horizontal
(90 degrees). Distance remains scene meters, distinct from geographic radius.

Choose `initialCamera:` for a startup camera or `cameraPosition:` for controlled state; they cannot
be supplied together. The controlled binding retains gesture read-back. Camera focus defaults to
`.chunkCenter`; `.coordinate(coordinate, altitude: .clampToGround)` follows the current projection
as the ground changes.

Use ``DioramaReader`` for scoped imperative commands, or read `@Environment(\.dioramaCamera)` inside
`.dioramaControls`. Each reader owns one host. Proxy commands run repeatedly even for equal values;
`setCamera`, `fit`, `reset`, and `cancel` therefore suit buttons and repeated app actions. An
`.accepted(id)` result is a receipt: inspect `result(for:)` or `lastResult` for completion,
cancellation, invalid targets, constrained fits, or a required ground navigation. A camera fit
never changes ground geography implicitly.

Fits support `.chunk`, `.bounds(...)`, and `.contentIDs(["trail"])`. Attach stable string fit IDs
with `.id("trail")` or the content constructor's `id:`. Styling modifiers preserve them. Fitting
uses actual relief and walls, aspect, safe areas, scoped control occlusion, and point padding.
Configure shared gesture/programmatic constraints with `.dioramaCameraLimits(...)`; its failable
value initializer accepts scene-meter distance ranges, pitch degrees, and `.insideChunk` or
`.unrestricted` focus policy. `.dioramaCameraFitInsets(...)` supplies persistent point insets.

Use `.dioramaCameraTransition(.easeInOut(duration: 0.6))` for declarative transitions and the proxy's
`transition:` argument for actions. Transitions use elapsed time and the shortest heading arc;
Reduce Motion makes them immediate. Check proxy capabilities: orbit and fit actions are unavailable
in AR and visionOS volumes. Ground navigation retains its existing behavior.

## Observe camera action boundaries

The original callback continues to receive a camera:

```swift
.onDioramaCameraChange { camera in
    saveOrbit(camera)
}
```

Supply a frequency to receive the richer context:

```swift
.onDioramaCameraChange(frequency: .onEnd) { context in
    saveOrbit(context.camera)
    // context.phase and context.origin describe the applied movement.
}
```

Camera context has its own `.changing`, `.ended`, and `.cancelled` phases. `.continuous` reports
applied poses and a terminal update; `.onEnd` reports completion or cancellation of the actual
gesture or programmatic action, rather than waiting on a generic settle timer. Origins retain
their existing meaning. Use geographic navigation observation when you
need center and radius. A visionOS volume has no orbit camera: camera bindings are accepted as
no-ops, camera callbacks do not fire, and navigation contexts have `camera == nil`.

## Replace loading UI without losing attribution

```swift
DioramaView(initialRegion: region)
    .dioramaLoadingOverlay { context in
        if case .loading = context.state {
            ProgressView("Preparing terrain")
        } else if case .failed = context.state {
            Button("Retry") { context.retry() }
        }
    }
```

This replaces the built-in loading, error, and streaming presentation. `streamingProgress` is
available for photorealistic content and is `nil` for raster terrain. `retry()` acts only in the
failed state. Return no content for phases you do not need, or use
`.dioramaLoadingOverlayHidden()` to hide all loading presentation, including a custom overlay.
Observe `.onDioramaLoadingChange` to present status elsewhere. Required source attribution remains
independent of loading presentation; provider branding obligations still apply.

## Add controls for each diorama

Place built-in controls in a diorama controls builder to give them a local target:

```swift
DioramaView(initialRegion: region)
    .dioramaControls(alignment: .topLeading) {
        VStack {
            DioramaCompass()
            DioramaResetButton()
        }
        .buttonStyle(.bordered)
    }
```

The builder is evaluated independently for each diorama in its hierarchy, and the nearest
`.dioramaControls` modifier wins. The target exists only inside that diorama's controls overlay.
Outside the builder, the reset button is disabled and the compass is hidden. Choose the layout,
alignment, and button style to fit your interface.

Reset restores the last application-requested geographic region and orbit, using their startup
defaults if no later request exists. App ground requests and live `region:` changes update the
home region; gesture read-back and style changes do not. Reset preserves style, effects, content,
and selection. It cancels a globe journey and pending pan, leaves camera route-follow mode while
route playback continues, and writes programmatic values back to the bindings. In visionOS it
also resets chunk orientation while keeping the volume's placement. AR placement is preserved.

The compass is available for iOS/macOS orbit views. It faces north while preserving camera tilt
and distance, without refetching the ground or replacing the orbit that reset will restore. It
is hidden in visionOS volumes, AR, globe presentation, and route-follow mode. Controls are
unavailable during ordinary loading or a pending ground command; reset can cancel a globe return.

## Give custom providers a stable source identity

Existing `Tiles3DProvider` conformers compile with the default `sourceID == nil`. Each newly
constructed photorealistic style using such a provider receives a distinct identity, so rebuilding
that style can now reload conservatively. Retain the constructed style between body evaluations
to preserve its identity, or implement:

```swift
var sourceID: Tiles3DSourceID? {
    Tiles3DSourceID("my-terrain-asset", revision: "2026-10")
}
```

Equal source identities promise interchangeable fetching for providers of the same type. Include
asset, endpoint, data revision, and authorization context whenever they can change the dataset.
Keep identity stable for the provider's lifetime; supply a new provider and identity for a new
source. Attribution is display text and does not identify a dataset. Source IDs retain a digest
of their inputs. Built-in providers already include their relevant source settings.

## Use explicit units and local modifiers

`DioramaRegion.radius` uses geographic meters. `.dioramaPhysicalSize(0.8)` describes the chunk's
physical span: real meters in a visionOS volume or AR placement, and a viewport reference in an
embedded orbit view. `DioramaCamera.distance` uses scene meters. A polyline's
`.stroke(.blue, width: .physicalMeters(0.003))` uses diorama meters, independent of geographic zoom.
Angles use SwiftUI `Angle`; `.relativeToGround` altitude uses geographic elevation units.

`.dioramaShape` and `.dioramaPhysicalSize` override initializer values, with the nearest modifier
winning. Content group modifiers supply defaults; child modifiers win. Repeating a modifier on
the same styled content layer replaces its earlier value. Existing initializer tint, altitude,
and line-width styling remain available.

## Release checks

These are checks to perform before release, not a claim of completed device verification:

- Compile representative consumer examples with plain `import Maquette`, including old items-only
  conformers, String selection, typed tags, `ForEach`, and both camera callback forms.
- Run semantic tests for identity, modifier precedence, provider reload equality, geographic
  requests versus gesture read-back, camera geometry, fitting, constraints, cancellation,
  supersession, transition timing, and Reduce Motion.
- On iOS/iPadOS, verify drag, multi-touch orbit, pinch, selection taps, and globe return with the
  new bindings; verify AR placement and return from AR on a supported physical device.
- On macOS, verify mouse drag, option-drag, trackpad pinch, and scroll zoom.
- In visionOS, verify volume pan and ground zoom, geographic read-back, and the absence of orbit
  callbacks. The user moves physically around the volume.
- Verify custom loading/retry/hiding with success and failure, while source attribution remains
  visible. Check automatic pan and explicit zero-margin compatibility separately.
- Put two dioramas on screen and verify reader proxies and controls affect only their own host.
  Verify fits across aspect ratios, safe areas, control occlusion, relief, and content IDs. Check
  repeated equal camera actions, mid-transition cancellation, and projection changes. Check compass
  visibility in AR, volumes, globe, and route-follow mode; verify reset home behavior after app
  requests, gestures, globe return, and route playback.

Minimum targets remain iOS/iPadOS 18, macOS 15, and visionOS 2. AR placement is iOS/iPadOS only.
watchOS lacks RealityKit; tvOS is not a supported interaction platform.


## Geographic overlay migration

The GeoJSON wrapper is now ``DioramaFeature`` and its style is ``DioramaFeatureStyle``.
Replace `DioramaAnnotation(feature)` with `DioramaFeature(feature)` and `AnnotationStyle(...)`
with `DioramaFeatureStyle(...)`. The old spellings are removed before 1.0. Custom SwiftUI labels
are a separate upcoming API.

``DioramaPolygon`` supports holes and multipolygons; ``DioramaCircle`` takes a geographic radius.
Use `.fill(...)` and `.stroke(..., style:)` independently, including on `DioramaFeature`.
``DioramaStrokeStyle`` defines caps, joins, miter limits, dash lengths, and phase. Widths and dash
lengths use either physical chunk meters or geographic meters. Shape selection requires `.tag(...)`
matching the binding's type; untagged marker String-ID compatibility remains available.

``DioramaImageOverlay`` takes a north-up ``GeographicBounds`` and an immutable decoded
``DioramaImageResource``. Keep its ID/revision stable for unchanged pixels, and change the revision
when pixels change. Its attribution supplements the terrain attribution. Ground-conforming overlays
currently require raster terrain; unsupported photorealistic placement is omitted with a diagnostic.
