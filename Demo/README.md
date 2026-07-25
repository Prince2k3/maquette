# Maquette Demo

An iOS app that renders terrain chunks from live elevation and imagery tiles, used to verify the
chunk pipeline visually — unit tests cover the geometry buffers, but only a running app shows
whether the result actually reads as a slice of the earth.

## Running

The Xcode project is generated from `project.yml`, so it is not checked in:

```bash
cd Demo && xcodegen generate && open MaquetteDemo.xcodeproj
```

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and network
access — every preset fetches real Mapzen elevation and ESRI imagery tiles at launch, so the first
render of each takes a few seconds.

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

Drag to orbit, pinch to zoom.

The Pan preset adds an Orbit/Pan switch. In Pan mode the drag slides the terrain beneath the
chunk's outline instead of moving the camera — the silhouette, walls, and strata stay put while the
ground moves under them. It fetches a region 80% wider than the chunk to pan through, and the offset
clamps at that edge.
