# ``Maquette``

Configurable terrain chunks of the real world — a slice of the earth lifted out of the ground and
set on a table.

## Overview

The core object is a closed solid, not a map surface: real terrain and satellite imagery on top,
cut walls showing geological strata down the sides, and a closing face underneath. Every aspect of
the presentation is configurable — the outline it is cut to, how deep the earth goes, how the cut
walls read, and what it rests on.

``DioramaView`` follows MapKit's SwiftUI shape: the initializer carries place and interaction, view
modifiers carry style and observation, and a result builder carries content.

```swift
DioramaView(
    region: DioramaRegion(center: canyon, radius: 6000),
    cameraPosition: $position
) {
    DioramaMarker("Yavapai Point", coordinate: overlook, tint: .orange)
}
.dioramaStyle(.standard(exaggeration: 1.6, chunk: .canyon, panRange: 0.8))
.globeTransition()
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:migrating-to-the-swiftui-api>
- ``DioramaView``
- ``DioramaRegion``
- ``DioramaShape``
- ``DioramaStyle``

### Camera and interaction

- ``DioramaCamera``
- ``DioramaCameraPosition``
- ``DioramaCameraFocus``
- ``DioramaReader``
- ``DioramaCameraProxy``
- ``DioramaCameraLimits``
- ``DioramaCameraTransition``
- ``DioramaCameraFitTarget``
- ``DioramaCameraCapabilities``
- ``DioramaCameraRequestID``
- ``DioramaCameraActionResult``
- ``DioramaGroundPosition``
- ``DioramaNavigationContext``
- ``DioramaCameraChangeContext``
- ``DioramaUpdateFrequency``
- ``DioramaInteractionModes``
- ``DioramaCompass``
- ``DioramaResetButton``
- ``GlobeTransitionStyle``

### Content

- ``DioramaContent``
- ``DioramaContentBuilder``
- ``DioramaContentGroup``
- ``DioramaForEachContent``
- ``DioramaStyledContent``
- ``DioramaLineWidth``
- ``DioramaMarker``
- ``DioramaPolyline``
- ``DioramaPolygon``
- ``DioramaCircle``
- ``DioramaImageOverlay``
- ``DioramaImageResource``
- ``DioramaStrokeStyle``
- ``DioramaFeature``
- ``DioramaFeatureStyle``
- ``AltitudeReference``
- ``DioramaRoutePreview``
- ``RoutePreviewController``

### Appearance

- ``TerrainChunkStyle``
- ``StrataPalette``
- ``BuildingStyle``
- ``DioramaLoadingPolicy``
- ``DioramaEffect``
- ``HologramStyle``
- ``InkStyle``
- ``TerraceStyle``

### Data sources

- <doc:Providers>
- <doc:Attribution>
- ``ImagerySource``
- ``ElevationSource``
- ``Tiles3DProvider``
- ``Tiles3DSourceID``
- ``GoogleTiles3DProvider``
- ``CesiumIonTiles3DProvider``
- ``Tiles3DStyle``

### GeoJSON and measurement

- ``Coordinate``
- ``Feature``
- ``FeatureCollection``
- ``Geometry``
- ``Turf``

### Loading state

- ``DioramaLoadingState``
- ``DioramaLoadingContext``
- ``DioramaStreamingProgress``
- ``DioramaError``
