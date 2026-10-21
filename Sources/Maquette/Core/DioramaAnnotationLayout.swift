import Foundation

/// Deterministic screen layout, independent of SwiftUI and the rendering host.
enum DioramaAnnotationLayout {
    static let hostedLimit = 256
    static let visibleLimit = 64

    struct Candidate {
        var id: String
        var frame: CGRect
        var priority: Double
        var depth: Float
        var allowsOverlap: Bool
    }

    static func frame(at point: CGPoint, size: CGSize, anchorX: CGFloat, anchorY: CGFloat, offset: CGSize) -> CGRect {
        CGRect(x: point.x - size.width * anchorX + offset.width,
               y: point.y - size.height * anchorY + offset.height, width: size.width, height: size.height)
    }

    static func visible(_ candidates: [Candidate], limit: Int = visibleLimit) -> [String] {
        let sorted = candidates.enumerated().filter {
            let rect = $0.element.frame
            return rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
                && rect.width > 0 && rect.height > 0 && $0.element.depth.isFinite && $0.element.priority.isFinite
        }.sorted {
            if $0.element.priority != $1.element.priority { return $0.element.priority > $1.element.priority }
            if $0.element.depth != $1.element.depth { return $0.element.depth < $1.element.depth }
            return $0.offset < $1.offset
        }
        var occupied: [CGRect] = []
        var result: [String] = []
        for entry in sorted {
            guard result.count < max(0, limit) else { break }
            let candidate = entry.element
            if !candidate.allowsOverlap && occupied.contains(where: { $0.intersects(candidate.frame) }) { continue }
            result.append(candidate.id)
            if !candidate.allowsOverlap { occupied.append(candidate.frame.insetBy(dx: -2, dy: -2)) }
        }
        return result
    }
}
