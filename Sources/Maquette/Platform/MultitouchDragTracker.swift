import CoreGraphics
import Foundation

/// Extracts independent translation, pinch, and twist channels from concurrent touches.
struct MultitouchDragTracker {
    struct Thresholds {
        var translation: CGFloat = 3
        var rotationRadians: CGFloat = 2 * .pi / 180
        var scaleFraction: CGFloat = 0.01
        var spread: CGFloat = 2

        static let standard = Self()
        static let none = Self(translation: 0, rotationRadians: 0, scaleFraction: 0, spread: 0)
    }

    struct Update {
        let touchCount: Int
        let translation: CGSize
        /// Change in mean distance from the midpoint, in points.
        let spreadChange: CGFloat
        /// Signed twist, wrapped to [-pi, pi].
        let rotationChangeRadians: CGFloat
        /// Multiplicative pinch; 1 means no change.
        let scaleRatio: CGFloat
        var log2ScaleRatio: CGFloat { log2(scaleRatio) }
        /// Digitizer sample time. Invalid timestamps are discarded.
        let time: TimeInterval?
    }

    var thresholds: Thresholds
    private var previous: [AnyHashable: CGPoint] = [:]
    private var pendingTranslation = CGSize.zero
    private var pendingRotation: CGFloat = 0
    private var pendingLogScale: CGFloat = 0
    private var pendingSpread: CGFloat = 0
    private var translationRecognized = false
    private var rotationRecognized = false
    private var scaleRecognized = false

    init(thresholds: Thresholds = .standard) {
        self.thresholds = thresholds
    }

    /// Compatibility entry point: array indices act as identities. Callers with real touch IDs
    /// should use `update(touches:at:)` so enumeration changes and replacement fingers are safe.
    mutating func update(with locations: [CGPoint], at time: TimeInterval? = nil) -> Update? {
        update(touches: Dictionary(uniqueKeysWithValues: locations.enumerated().map { ($0.offset, $0.element) }), at: time)
    }

    /// Membership changes re-anchor every channel, even when the touch count stays the same.
    /// Before recognition, each channel accumulates motion independently. Crossing its threshold
    /// delivers the entire accumulated movement; subsequent samples deliver frame deltas.
    mutating func update<ID: Hashable>(touches: [ID: CGPoint], at time: TimeInterval? = nil) -> Update? {
        var current: [AnyHashable: CGPoint] = [:]
        for (id, point) in touches where point.x.isFinite && point.y.isFinite {
            current[AnyHashable(id)] = point
        }
        guard !current.isEmpty else {
            reset()
            return nil
        }
        guard current.count == previous.count, current.keys.allSatisfy({ previous[$0] != nil }) else {
            reset()
            previous = current
            return nil
        }
        let oldCenter = Self.centroid(previous)
        let center = Self.centroid(current)
        let oldSpread = Self.spread(previous, around: oldCenter)
        let spread = Self.spread(current, around: center)
        guard center.x.isFinite, center.y.isFinite, oldCenter.x.isFinite,
              oldCenter.y.isFinite, spread.isFinite, oldSpread.isFinite else {
            reset()
            return nil
        }
        var dot: CGFloat = 0
        var cross: CGFloat = 0
        // Match by identity rather than relying on dictionary enumeration order.
        for (id, point) in current {
            guard let old = previous[id] else { continue }
            let x = point.x - center.x, y = point.y - center.y
            let oldX = old.x - oldCenter.x, oldY = old.y - oldCenter.y
            dot += oldX * x + oldY * y
            cross += oldX * y - oldY * x
        }
        previous = current
        pendingTranslation.width += center.x - oldCenter.x
        pendingTranslation.height += center.y - oldCenter.y
        var translation = CGSize.zero
        if translationRecognized || hypot(pendingTranslation.width, pendingTranslation.height) >= thresholds.translation {
            translationRecognized = true
            translation = pendingTranslation
            pendingTranslation = .zero
        }

        var rotation: CGFloat = 0
        var scaleRatio: CGFloat = 1
        var spreadChange: CGFloat = 0
        // Coincident touches provide neither orientation nor scale. Re-anchor those channels so
        // separating the touches cannot produce a divide-by-zero or a delayed jump.
        if current.count > 1 && oldSpread > .ulpOfOne && spread > .ulpOfOne {
            if dot != 0 || cross != 0 { pendingRotation += atan2(cross, dot) }
            pendingLogScale += log(spread / oldSpread)
            pendingSpread += spread - oldSpread
            if rotationRecognized || abs(pendingRotation) >= thresholds.rotationRadians {
                rotationRecognized = true
                rotation = atan2(sin(pendingRotation), cos(pendingRotation))
                pendingRotation = 0
            }
            if scaleRecognized || abs(expm1(pendingLogScale)) >= thresholds.scaleFraction || abs(pendingSpread) >= thresholds.spread {
                scaleRecognized = true
                scaleRatio = exp(pendingLogScale)
                spreadChange = pendingSpread
                pendingLogScale = 0
                pendingSpread = 0
            }
        } else {
            pendingRotation = 0
            pendingLogScale = 0
            pendingSpread = 0
            rotationRecognized = false
            scaleRecognized = false
        }
        return Update(
            touchCount: current.count, translation: translation, spreadChange: spreadChange,
            rotationChangeRadians: rotation, scaleRatio: scaleRatio,
            time: time.flatMap { $0.isFinite ? $0 : nil }
        )
    }

    mutating func reset() {
        previous = [:]
        pendingTranslation = .zero
        pendingRotation = 0
        pendingLogScale = 0
        pendingSpread = 0
        translationRecognized = false
        rotationRecognized = false
        scaleRecognized = false
    }

    private static func centroid(_ points: [AnyHashable: CGPoint]) -> CGPoint {
        let count = CGFloat(points.count)
        return points.values.reduce(.zero) { total, point in
            CGPoint(x: total.x + point.x / count, y: total.y + point.y / count)
        }
    }

    private static func spread(_ points: [AnyHashable: CGPoint], around center: CGPoint) -> CGFloat {
        guard points.count > 1 else { return 0 }
        let count = CGFloat(points.count)
        return points.values.reduce(0) { $0 + hypot($1.x - center.x, $1.y - center.y) / count }
    }
}
