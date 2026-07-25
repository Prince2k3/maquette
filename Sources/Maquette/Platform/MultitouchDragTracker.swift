import CoreGraphics
import Foundation

/// Turns a stream of concurrent touch locations into frame-to-frame drag and pinch deltas,
/// so a one-finger drag can be told apart from a two-finger one.
///
/// `DragGesture` reports a translation but not how many fingers produced it, which is why
/// distinguishing pan from orbit needs the raw touches from `SpatialEventGesture`.
struct MultitouchDragTracker {
    /// Movement since the previous update.
    struct Update {
        /// Number of touches currently down.
        let touchCount: Int
        /// How far the touches' midpoint moved, in points.
        let translation: CGSize
        /// How much the touches spread apart, in points. Always `0` for a single touch.
        let spreadChange: CGFloat
    }

    private var previousCentroid: CGPoint?
    private var previousSpread: CGFloat = 0
    private var previousCount = 0

    /// Feeds the current touch locations and returns the movement since the last update.
    ///
    /// Returns `nil` when there is nothing to act on yet — no touches, the first update of a
    /// gesture, or the frame a finger was added or lifted. Re-anchoring on those frames is what
    /// keeps the view from jumping when the midpoint suddenly relocates.
    mutating func update(with locations: [CGPoint]) -> Update? {
        guard !locations.isEmpty else {
            reset()
            return nil
        }

        let centroid = Self.centroid(of: locations)
        let spread = Self.spread(of: locations, around: centroid)

        defer {
            previousCentroid = centroid
            previousSpread = spread
            previousCount = locations.count
        }

        guard locations.count == previousCount, let previousCentroid else { return nil }

        return Update(
            touchCount: locations.count,
            translation: CGSize(
                width: centroid.x - previousCentroid.x,
                height: centroid.y - previousCentroid.y
            ),
            spreadChange: spread - previousSpread
        )
    }

    /// Clears the anchor so the next gesture starts fresh.
    mutating func reset() {
        previousCentroid = nil
        previousSpread = 0
        previousCount = 0
    }

    // MARK: - Geometry

    private static func centroid(of locations: [CGPoint]) -> CGPoint {
        var total = CGPoint.zero
        for location in locations {
            total.x += location.x
            total.y += location.y
        }
        let count = CGFloat(locations.count)
        return CGPoint(x: total.x / count, y: total.y / count)
    }

    /// Mean distance from the midpoint, which generalizes pinch to any number of touches.
    private static func spread(of locations: [CGPoint], around centroid: CGPoint) -> CGFloat {
        guard locations.count > 1 else { return 0 }
        var total: CGFloat = 0
        for location in locations {
            total += hypot(location.x - centroid.x, location.y - centroid.y)
        }
        return total / CGFloat(locations.count)
    }
}
