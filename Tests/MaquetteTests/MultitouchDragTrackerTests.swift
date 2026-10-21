import CoreGraphics
import Foundation
import Testing
@testable import Maquette

@Suite("Multitouch Drag Tracker Tests")
struct MultitouchDragTrackerTests {
    @Test("The first update only anchors")
    func firstUpdateAnchors() {
        var tracker = MultitouchDragTracker()
        #expect(tracker.update(with: [CGPoint(x: 10, y: 10)]) == nil)
    }

    @Test("A single touch reports its movement")
    func singleTouchTranslation() throws {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(with: [CGPoint(x: 10, y: 10)])

        let result = tracker.update(with: [CGPoint(x: 25, y: 40)])
        let update = try #require(result)
        #expect(update.touchCount == 1)
        #expect(update.translation.width == 15)
        #expect(update.translation.height == 30)
        #expect(update.spreadChange == 0, "A lone touch cannot pinch")
    }

    @Test("Two touches report their midpoint's movement")
    func twoTouchTranslation() throws {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(with: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])

        let result = tracker.update(with: [
            CGPoint(x: 20, y: 10), CGPoint(x: 120, y: 10),
        ])
        let update = try #require(result)
        #expect(update.touchCount == 2)
        #expect(update.translation.width == 20)
        #expect(update.translation.height == 10)
        #expect(abs(update.spreadChange) < 0.0001, "Moving together is not a pinch")
    }

    @Test("Spreading touches apart reports a positive pinch")
    func pinchOutward() throws {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(with: [CGPoint(x: 40, y: 0), CGPoint(x: 60, y: 0)])

        let result = tracker.update(with: [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
        ])
        let update = try #require(result)
        // Mean distance from the midpoint goes from 10 to 50.
        #expect(abs(update.spreadChange - 40) < 0.0001)
        #expect(abs(update.translation.width) < 0.0001, "A symmetric pinch does not translate")
    }

    @Test("Adding a finger re-anchors instead of jumping")
    func addingTouchReanchors() throws {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(with: [CGPoint(x: 0, y: 0)])
        _ = tracker.update(with: [CGPoint(x: 10, y: 0)])

        // The midpoint leaps to (55, 0) when the second finger lands. Reporting that as movement
        // would snap the view, so this frame is swallowed.
        #expect(tracker.update(with: [CGPoint(x: 10, y: 0), CGPoint(x: 100, y: 0)]) == nil)

        let result = tracker.update(with: [
            CGPoint(x: 20, y: 0), CGPoint(x: 110, y: 0),
        ])
        let update = try #require(result)
        #expect(update.touchCount == 2)
        #expect(update.translation.width == 10)
    }

    @Test("Lifting a finger re-anchors instead of jumping")
    func removingTouchReanchors() throws {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(with: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        _ = tracker.update(with: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])

        #expect(tracker.update(with: [CGPoint(x: 0, y: 0)]) == nil)

        let result = tracker.update(with: [CGPoint(x: 5, y: 0)])
        let update = try #require(result)
        #expect(update.touchCount == 1)
        #expect(update.translation.width == 5)
    }

    @Test("Lifting every finger clears the anchor")
    func liftingAllTouchesResets() {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(with: [CGPoint(x: 10, y: 10)])
        #expect(tracker.update(with: []) == nil)

        // The next gesture starts fresh rather than measuring from the old anchor.
        #expect(tracker.update(with: [CGPoint(x: 500, y: 500)]) == nil)
    }

    @Test("Reset drops the anchor")
    func resetDropsAnchor() {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(with: [CGPoint(x: 10, y: 10)])
        tracker.reset()
        #expect(tracker.update(with: [CGPoint(x: 20, y: 20)]) == nil)
    }

    @Test("Three touches are tracked like two")
    func threeTouches() throws {
        var tracker = MultitouchDragTracker()
        let start = [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 0, y: 30)]
        _ = tracker.update(with: start)

        let result = tracker.update(with: start.map {
            CGPoint(x: $0.x + 7, y: $0.y - 3)
        })
        let update = try #require(result)
        #expect(update.touchCount == 3)
        #expect(update.translation.width == 7)
        #expect(update.translation.height == -3)
    }
}

@Suite("Stable Multitouch Channels")
struct StableMultitouchChannelTests {
    private func pair(angle: CGFloat = 0, radius: CGFloat = 50) -> [Int: CGPoint] {
        let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        return [1: CGPoint(x: -point.x, y: -point.y), 2: point]
    }

    @Test("Enumeration order cannot reverse the twist vector")
    func reorderedTouches() throws {
        var tracker = MultitouchDragTracker(thresholds: .none)
        _ = tracker.update(touches: [1: CGPoint(x: -50, y: 0), 2: CGPoint(x: 50, y: 0)])
        let sample1 = tracker.update(touches: [2: CGPoint(x: 50, y: 0), 1: CGPoint(x: -50, y: 0)])
        let update = try #require(sample1)
        #expect(update.rotationChangeRadians == 0)
        #expect(update.scaleRatio == 1)
    }

    @Test("Replacing a finger at the same count re-anchors")
    func replacement() throws {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(touches: pair())
        #expect(tracker.update(touches: [1: CGPoint(x: -50, y: 0), 3: CGPoint(x: 500, y: 0)]) == nil)
        let sample2 = tracker.update(touches: [1: CGPoint(x: -45, y: 0), 3: CGPoint(x: 505, y: 0)])
        let update = try #require(sample2)
        #expect(update.translation.width == 5)
        #expect(update.scaleRatio == 1)
        #expect(update.rotationChangeRadians == 0)
    }

    @Test("One to two to one touches resets channel recognition")
    func membershipTransitions() throws {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(touches: [1: CGPoint.zero])
        #expect(tracker.update(touches: pair()) == nil)
        #expect(tracker.update(touches: [2: CGPoint(x: 50, y: 0)]) == nil)
        let sample3 = tracker.update(touches: [2: CGPoint(x: 51, y: 0)])
        let update = try #require(sample3)
        #expect(update.translation == .zero)
        #expect(update.rotationChangeRadians == 0)
        #expect(update.scaleRatio == 1)
    }

    @Test("Twist crosses the angle seam by the short arc")
    func angleWrap() throws {
        var tracker = MultitouchDragTracker(thresholds: .none)
        _ = tracker.update(touches: pair(angle: 179 * .pi / 180))
        let sample4 = tracker.update(touches: pair(angle: -179 * .pi / 180))
        let update = try #require(sample4)
        #expect(abs(update.rotationChangeRadians - 2 * .pi / 180) < 0.00001)
    }

    @Test("Pinch and twist remain simultaneous independent channels")
    func pinchAndTwist() throws {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(touches: pair())
        let sample5 = tracker.update(touches: pair(angle: .pi / 6, radius: 100))
        let update = try #require(sample5)
        #expect(abs(update.rotationChangeRadians - .pi / 6) < 0.00001)
        #expect(abs(update.scaleRatio - 2) < 0.00001)
        #expect(abs(update.log2ScaleRatio - 1) < 0.00001)
        #expect(abs(update.spreadChange - 50) < 0.00001)
        #expect(update.translation == .zero)
    }

    @Test("Jitter is suppressed and threshold crossing retains accumulated movement")
    func accumulatedThresholds() throws {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(touches: pair())
        let sample6 = tracker.update(touches: pair(angle: .pi / 180, radius: 50.2))
        let jitter = try #require(sample6)
        #expect(jitter.rotationChangeRadians == 0)
        #expect(jitter.scaleRatio == 1)
        let sample7 = tracker.update(touches: pair(angle: 3 * .pi / 180, radius: 51))
        let crossed = try #require(sample7)
        #expect(abs(crossed.rotationChangeRadians - 3 * .pi / 180) < 0.00001)
        #expect(abs(crossed.scaleRatio - 1.02) < 0.00001)
        let sample8 = tracker.update(touches: pair(angle: 3.1 * .pi / 180, radius: 51.1))
        let small = try #require(sample8)
        #expect(abs(small.rotationChangeRadians - 0.1 * .pi / 180) < 0.00001)
        #expect(abs(small.scaleRatio - 51.1 / 51) < 0.00001)
    }

    @Test("Translation accumulates independently of pinch recognition")
    func accumulatedTranslation() throws {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(touches: [1: CGPoint.zero])
        let sample9 = tracker.update(touches: [1: CGPoint(x: 1, y: 0)])
        #expect(try #require(sample9).translation == .zero)
        let sample10 = tracker.update(touches: [1: CGPoint(x: 2, y: 0)])
        #expect(try #require(sample10).translation == .zero)
        let sample11 = tracker.update(touches: [1: CGPoint(x: 3, y: 0)])
        #expect(try #require(sample11).translation.width == 3)
        let sample12 = tracker.update(touches: [1: CGPoint(x: 3.1, y: 0)])
        #expect(try #require(sample12).translation.width > 0)
    }

    @Test("Coincident and invalid touches cannot create pinch or twist jumps")
    func degenerates() throws {
        var tracker = MultitouchDragTracker()
        _ = tracker.update(touches: [1: CGPoint.zero, 2: CGPoint.zero])
        let sample13 = tracker.update(touches: pair(), at: .infinity)
        let separated = try #require(sample13)
        #expect(separated.scaleRatio == 1)
        #expect(separated.rotationChangeRadians == 0)
        #expect(separated.time == nil)
        #expect(tracker.update(touches: [1: CGPoint(x: CGFloat.nan, y: 0), 2: CGPoint.zero]) == nil)
        tracker.reset()
        #expect(tracker.update(touches: pair()) == nil)
    }
}
