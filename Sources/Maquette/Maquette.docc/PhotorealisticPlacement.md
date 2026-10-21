# Place content on photorealistic meshes

Anchor geographic content to the visible triangles of streamed 3D Tiles.

## Use the same content vocabulary

Markers, custom SwiftUI annotations, polylines, polygons, circles, GeoJSON features, and image overlays
use the same geographic coordinates and altitude references as raster terrain. Select a photorealistic
style and declare the content normally:

```swift
DioramaView(region: region) {
    DioramaMarker("Surface anchor", coordinate: viewpoint)
    DioramaCircle(center: viewpoint, radius: 100)
        .fill(.cyan.opacity(0.25))
        .stroke(.cyan, width: .geographicMeters(5))
}
.dioramaStyle(.photorealistic(provider: provider))
```

The query surface contains visible tile triangles after clipping and LOD selection. Hidden ancestors,
unloaded children, the tray, and generated cut walls do not supply ground. Pan and datum changes use
the same scene transform as the visible model.

## Understand the surface choice

Ground placement means the highest triangle under a horizontal point. A pin over a roof sits on that
roof; a pin over a bridge sits on the bridge. The library does not classify photogrammetry into roads,
buildings, vegetation, or bare earth. Use an absolute altitude when your data supplies a known height
and you need to bypass this choice. On the 3D Tiles path, absolute altitudes use metres above the
WGS84 ellipsoid, matching the frame in which the tiles arrive.

Ground-clamped areas and stroke footprints intersect the surface triangles, rather than connecting
height samples across ridges or holes. Overlapping surfaces use the upper envelope. Image fragments
retain their original geographic UV extent, and ground-relative fragments preserve their altitude
offset. Vertical faces participate in label occlusion but have no horizontal area for a ground drape;
this API does not wrap images down building facades.
Nearly vertical faces that cannot provide a stable height plane are also excluded from placement;
their triangles remain available for line-of-sight occlusion.

## Expect partial coverage while streaming

Queries cover the current resident visible mesh. A missing surface returns no placement, rather than
zero height. Ground-dependent markers and labels stay hidden there; area and line fragments omit
uncovered portions. Absolute-altitude content can still render without a resident surface.

When LOD visibility changes, the host replaces its query snapshot and refreshes dependent content.
An old tile cannot keep answering after it disappears. New detail can move an anchor as the visible
geometry improves. Overlay geometry is prepared asynchronously; pending replacement overlays stay
hidden until ready. This avoids displaying stale geometry, but does not promise continuous coverage
during a streaming update.

Surface construction and draping use bounded geometry work. Invalid or over-budget input is omitted
with a diagnostic instead of freezing the scene or substituting a flat datum. A query implementation
being available does not guarantee coverage at every coordinate.

## Choose label occlusion

The default `.annotationOcclusion(.terrain)` uses visible photogrammetry for screen line-of-sight
queries, including building facades. `.annotationOcclusion(.alwaysVisible)` keeps a placed label
visible through the mesh. Neither policy creates a ground anchor where surface coverage is absent.
visionOS attachments retain native depth testing and their physical annotation sizing.

The demo's City, Trail, and Pan 3D presets include a pin, label, line, filled polygon, circle, and
north-up image grid. Inspect them as tiles refine and while panning. These are live provider examples;
their coverage and detail depend on the configured provider and network.
