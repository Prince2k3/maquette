# Maquette

A Swift package that renders **configurable terrain chunks of the real world** — a slice of the
earth lifted out of the ground and set on a table. Real elevation and satellite imagery on top,
geological strata down the cut sides, a closing face underneath: a solid, not a draped map.

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
    @State private var selected: DioramaAnnotation.ID?

    var body: some View {
        DioramaView(
            region: DioramaRegion(
                center: CLLocationCoordinate2D(latitude: 36.0544, longitude: -112.1401),
                radius: 6000
            ),
            position: $position,
            selection: $selected
        ) {
            DioramaMarker("Yavapai Point",
                          coordinate: CLLocationCoordinate2D(latitude: 36.0667, longitude: -112.1170),
                          tint: .orange)
        }
        .dioramaStyle(.standard(exaggeration: 1.6, chunk: .canyon, panRange: 0.8))
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
