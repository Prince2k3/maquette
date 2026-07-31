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

A non-zero `panRange` lets one finger slide the terrain beneath the fixed outline, indefinitely —
tiles roll in as the ground moves. Pinching zooms the *map*, not the camera, and
`.globeTransition()` lets a zoom-out dissolve into a spinnable globe.

```swift
DioramaView(region: region, position: $cameraPosition)
    .dioramaStyle(.standard(chunk: .canyon, panRange: 0.8))
    .globeTransition()
```

## Observe and drive

- `position:` is the parallel of `MapCameraPosition` — set it to move the camera, read it back as
  the user orbits (`positionedByUser` says which happened).
- `selection:` receives the identity of a tapped marker.
- `onDioramaLoadingChange(_:)` reports load phases; the built-in overlay still shows the spinner
  and retry affordance.
- The region, style, and content are all live: hand the view different values and the diorama
  relocates, rebuilds, or re-applies in place.
