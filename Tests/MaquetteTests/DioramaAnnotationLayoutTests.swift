import Foundation
import Testing
@testable import Maquette

@Suite("Projected annotation layout")
struct DioramaAnnotationLayoutTests {
    @Test func anchorAndOffset() {
        let frame = DioramaAnnotationLayout.frame(at: CGPoint(x: 100, y: 100), size: CGSize(width: 40, height: 20), anchorX: 0.5, anchorY: 1, offset: CGSize(width: 3, height: -4))
        #expect(frame == CGRect(x: 83, y: 76, width: 40, height: 20))
    }
    @Test func priorityOverlapAndBudget() {
        let candidates = [
            DioramaAnnotationLayout.Candidate(id: "low", frame: CGRect(x: 0, y: 0, width: 40, height: 20), priority: 0, depth: 1, allowsOverlap: false),
            .init(id: "high", frame: CGRect(x: 0, y: 0, width: 40, height: 20), priority: 1, depth: 2, allowsOverlap: false),
            .init(id: "other", frame: CGRect(x: 80, y: 0, width: 20, height: 20), priority: 0, depth: 1, allowsOverlap: false)
        ]
        #expect(DioramaAnnotationLayout.visible(candidates, limit: 64) == ["high", "other"])
        #expect(DioramaAnnotationLayout.visible(candidates, limit: 1) == ["high"])
    }
    @Test func allowedOverlapAndStableTies() {
        let candidates = ["a", "b"].map { DioramaAnnotationLayout.Candidate(id: $0, frame: CGRect(x: 0, y: 0, width: 30, height: 20), priority: 0, depth: 1, allowsOverlap: true) }
        #expect(DioramaAnnotationLayout.visible(candidates, limit: 64) == ["a", "b"])
    }
    @Test func invalidFramesAreOmitted() {
        #expect(DioramaAnnotationLayout.visible([.init(id: "bad", frame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10), priority: 0, depth: 1, allowsOverlap: true)], limit: 64).isEmpty)
    }
}
