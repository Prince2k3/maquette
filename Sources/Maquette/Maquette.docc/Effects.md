# Effects

Restyle a chunk that already exists — no refetch, no rebuild.

## Applying an effect

```swift
DioramaView(region: region)
    .dioramaStyle(.standard(chunk: .canyon, panRange: 0.8))
    .dioramaEffect(.ink)
```

An effect is deliberately separate from ``DioramaStyle``: a style change reloads the substrate,
an effect repaints it. All three survive panning — lines re-trace and fills re-cut as the ground
slides — and a rolling tile fetch does not revert them.

## The effects

- ``DioramaEffect/hologram``: projected contour rings and outline loops over a darkened chunk,
  with an optional pedestal. ``HologramStyle`` controls color, spacing, and the pedestal.
- ``DioramaEffect/ink``: an inked-illustration look — the cut outline traced, terrain creases
  drawn as lines with a per-patch density budget, imagery flattened to cel-shaded tonal bands.
  ``InkStyle`` controls weights and banding.
- ``DioramaEffect/terraced``: the chunk cut into stacked flat steps like a contour model built
  from sheets of card, each step painted the color the ground at that height actually is —
  canyon country comes out in ochres, a forested volcano in greens and snow, from the same
  unmodified effect. ``TerraceStyle`` controls the ladder and, optionally, an authored palette.

Lines are real geometry, not a screen-space pass — that is what lets one implementation serve
visionOS, iOS, and macOS alike. The trade is that line weight is world-space, so lines thin as the
camera pulls back.
