# Custom SwiftUI Annotations

Attach native SwiftUI labels and controls to geographic coordinates with ``DioramaAnnotation``.
Use ``DioramaMarker`` for a standard pin, or supply a view when a place needs its own presentation.

## Preserve label state with stable identity

A collection's IDs keep each label's `@State` alive when coordinates, text, styling, or collection
order change. An explicit annotation `id:` or `.id(_:)` also establishes identity; changing that
ID starts a new label lifetime. Anonymous standalone labels follow their builder declaration.

```swift
import Maquette
import SwiftUI

struct Place: Identifiable, Sendable {
    let id: UUID
    var name: String
    var coordinate: Coordinate
}

struct PlaceLabel: View {
    let name: String
    @State private var saved = false

    var body: some View {
        VStack(spacing: 4) {
            Text(name).font(.headline)
            Button(saved ? "Saved" : "Save place") { saved.toggle() }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PlacesView: View {
    let region: DioramaRegion
    let places: [Place]
    @State private var selection: UUID?

    var body: some View {
        DioramaView(region: region, selection: $selection) {
            ForEach(places) { place in
                DioramaAnnotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
                    PlaceLabel(name: place.name)
                }
                .annotationOffset(y: -8)
                .annotationPriority(10)
                .annotationOcclusion(.terrain)
                .annotationOverlap(.avoid)
                .annotationScale(metersPerPoint: 0.001)
                .tag(place.id)
            }
        }
    }
}
```

The label's `Button` handles its own action. A tap on the label background toggles its typed
`.tag` selection; an already selected tag clears selection. Custom labels require a matching tag,
including when the selection binding contains `String`: their annotation IDs do not provide the
legacy selection fallback that untagged markers support. Dragging the label background navigates
the diorama after the drag threshold; native controls retain their own input handling.

## Place and prioritize labels

`anchor:` defaults to `.bottom`. It attaches that point of the label to its geographic position.
`.annotationOffset(x:y:)` adds SwiftUI points, with positive Y downward. Tint, opacity, and
`.altitudeReference(_:)` work with custom annotations too.

On iOS, iPadOS, and macOS, the anchor must lie inside the chunk and project inside the viewport,
in front of the camera. Labels outside those constraints are hidden; a label may extend past its
anchor and is clipped at the viewport edge. Labels are hidden during the globe handoff.

The first **256 annotations in declaration order** are hosted. Within that admitted group, screen
layout shows at most **64** labels: larger `.annotationPriority(_:)` values win, then nearer labels,
then declaration order. Priority does not admit an annotation beyond the first 256.
`.annotationOverlap(.avoid)` is the default and suppresses conflicting labels;
`.annotationOverlap(.allow)` permits overlap, while retaining the visible-label limit.

Hosted labels remain mounted while hidden by layout, terrain, the viewport, or a globe transition,
so their state survives those visibility changes. Removing an annotation ends its lifetime;
reinserting it creates fresh state. State retention is limited to the hosted budget.

## Choose occlusion and spatial size

The default `.annotationOcclusion(.terrain)` hides a screen label when terrain blocks the line
of sight to its anchor. On visionOS, the label is a native RealityView attachment and participates
in physical depth testing. `.annotationOcclusion(.alwaysVisible)` draws over terrain on both
presentations. Off-chunk anchors and labels hidden during a transition stay hidden; screen labels
still obey viewport constraints.

visionOS attachments face the viewer and share the same anchor and offset semantics.
`.annotationScale(metersPerPoint:)` sets their physical size, defaulting to `0.001` metres per
SwiftUI point. It has no effect on screen labels. Up to 256 attachments are hosted; the screen's
64-label overlap layout does not apply to a volume. Without a head pose, volumetric annotations
do not promise priority-based screen overlap avoidance.

Ground-clamped and ground-relative annotations over photorealistic 3D Tiles use the highest visible
mesh beneath the coordinate. A rooftop or bridge is a surface; placement does not infer the road
underneath it. Anchors with no resident surface stay hidden and return when tiles provide coverage.
Screen labels use the visible mesh for terrain occlusion, including vertical faces; visionOS labels
use native depth testing. An absolute-altitude label remains available without ground with
`.altitudeReference(.absolute)` and an altitude on its coordinate. See <doc:PhotorealisticPlacement>
for streaming and placement limits.

## Keep places accessible beyond the scene

Give each annotation a useful title and provide accessible labels for its controls. Visible custom
labels expose their native SwiftUI accessibility content and selection state. Off-screen,
occluded, suppressed, and unhosted labels are not a substitute for an accessible list of places.
For complete discovery, offer an application-owned list or search interface alongside the scene,
using the same models and selection binding.

For the surrounding view and content builder, see <doc:GettingStarted>. For compatibility with
the earlier GeoJSON annotation vocabulary, see <doc:migrating-to-the-swiftui-api>.
