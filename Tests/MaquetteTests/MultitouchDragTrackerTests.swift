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
