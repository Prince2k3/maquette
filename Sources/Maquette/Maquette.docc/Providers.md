# Data Sources

Where the ground comes from, what it costs, and which keys you need.

## Raster terrain (the default pipeline)

A terrain chunk is built from two tile streams: elevation and imagery. Both defaults are free and
need no key.

| Source | Selects with | Key |
|--------|--------------|-----|
| ESRI World Imagery | ``ImagerySource/esriSatellite`` | none |
| Mapzen Terrarium elevation | ``ElevationSource/mapzen`` | none |
| MapTiler satellite | ``ImagerySource/mapTilerSatellite(apiKey:)`` | MapTiler key |
| MapTiler terrain | ``ElevationSource/mapTiler(apiKey:)`` | MapTiler key |

```swift
.dioramaStyle(.standard(
    imagery: .mapTilerSatellite(apiKey: key),
    elevationSource: .mapTiler(apiKey: key)
))
```

Tiles cache on disk and in memory, so revisiting a region does not refetch it.

## Photorealistic 3D Tiles

``DioramaStyle/photorealistic(provider:style:panRange:)`` streams OGC 3D Tiles photogrammetry and
cuts it to the outline.

```swift
.dioramaStyle(.photorealistic(
    provider: GoogleTiles3DProvider(apiKey: googleKey),
    style: .detailed
))
```

**Cost.** Google bills the *root tileset request only* — session tokens and individual tiles are
free — so a diorama costs roughly one billable event per load, however much geometry it streams.
``GoogleTiles3DProvider`` caches the root (well inside the session's observed lifetime), so preset
switches, reloads, and quick relaunches collapse into a single billable request.

**Radius matters.** Level of detail is chosen from on-screen size, so a wide region is a *small*
region: ten kilometres of city in a dinner-plate chunk leaves a building two pixels tall and the
tileset correctly refuses to refine. Roughly a kilometre is where facades read as facades.

**Attribution is required.** See <doc:Attribution>.

## Custom providers

``Tiles3DProvider`` is three requirements: the root tileset's bytes, a tile's content bytes, and
an attribution string. The library parses the wire format; a provider only fetches.
