# The Globe Handoff

Zoom out past the map's edge — fingers pinching together — and the chunk dissolves into a
spinnable globe; zoom back in to cut a chunk from wherever you left it pointing.

## How it behaves

Apply ``SwiftUICore/View/globeTransition(_:)`` to opt in. From then on:

- **A pinch zooms the map, not the camera.** The chunk stays the same object on the table while
  the ground beneath it widens, re-fetching coarser tiles as it goes. Panning keeps working the
  whole way out.
- **The handoff is an animation, and a pinch triggers it rather than scrubs it.** When the map has
  no more ground to widen onto, the chunk dissolves into the globe over about a second, whatever
  the fingers do meanwhile. Coming back is the same in reverse.
- **The globe steers like a map.** North stays up; a drag walks the docked point along parallels
  and meridians, clamped at Mercator's edge where the data ends.
- **The return relocates.** Zooming in at the globe — fingers spreading apart — commits a descent
  onto the ground under the centre, fetching it during the dissolve. The rebuilt chunk comes back
  at the breadth you were looking at, so the way home is the way out reversed.

## Styling

``GlobeTransitionStyle`` controls the globe's radius, imagery zoom, and transition durations. The
same raster imagery the chunk uses textures the sphere, so no extra data source is involved.
