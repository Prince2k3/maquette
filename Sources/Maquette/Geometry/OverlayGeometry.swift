import Foundation
import simd

/// Raw geometry diagnostics. Callers decide how to associate an error with a content identity.
enum OverlayGeometryError: Error, Equatable, Sendable {
    case nonFiniteInput, degenerateRing, selfIntersection, invalidHole
    case invalidSurface, invalidWidth, invalidRadius, invalidProjection, budgetExceeded
    case unsupportedSurface
}

struct OverlayGeometryLimits: Sendable {
    var maxInputVertices = 10_000
    var maxTriangles = 200_000
    var maxOperations = 5_000_000
    var maxCircleSegments = 2_048
}

struct OverlayWork: Sendable {
    let limits: OverlayGeometryLimits
    private var remaining: Int
    init(_ limits: OverlayGeometryLimits) throws {
        try Task.checkCancellation()
        guard limits.maxInputVertices > 0, limits.maxTriangles > 0,
              limits.maxOperations > 0, limits.maxCircleSegments >= 4 else {
            throw OverlayGeometryError.budgetExceeded
        }
        self.limits = limits
        remaining = limits.maxOperations
    }
    // Keep constant charges cheap in resident-face and fragment-fan loops.
    @inline(__always)
    mutating func spend(_ count: Int = 1) throws {
        if remaining & 1023 == 0 { try Task.checkCancellation() }
        guard count >= 0, count <= remaining else { throw OverlayGeometryError.budgetExceeded }
        remaining -= count
    }
    func checkTriangles(_ count: Int) throws {
        guard count <= limits.maxTriangles else { throw OverlayGeometryError.budgetExceeded }
    }
}

/// All planar operations preserve these attributes, including newly inserted intersections.
/// Altitude is geographic; only the projection may convert it to diorama Y.
struct OverlayVertex: Sendable, Equatable {
    var point: SIMD2<Double>
    var uv: SIMD2<Double> = .zero
    var altitude: Double = 0
    var isFinite: Bool {
        point.x.isFinite && point.y.isFinite && uv.x.isFinite && uv.y.isFinite && altitude.isFinite
    }
    func interpolated(to other: Self, at t: Double) -> Self {
        // Retain local-delta precision normally; use weighted endpoints only when subtracting
        // finite opposite attributes overflows. The interpolation itself can still be finite.
        func blend(_ a: Double, _ b: Double) -> Double {
            let delta = b - a
            return delta.isFinite ? a + delta * t : a * (1 - t) + b * t
        }
        return Self(point: point + (other.point - point) * t,
                    uv: .init(blend(uv.x, other.uv.x), blend(uv.y, other.uv.y)), altitude: blend(altitude, other.altitude))
    }
}

struct OverlayTriangle: Sendable {
    var a: OverlayVertex
    var b: OverlayVertex
    var c: OverlayVertex
    var vertices: [OverlayVertex] { [a, b, c] }
    var isFinite: Bool { a.isFinite && b.isFinite && c.isFinite }
    var bounds: OverlayBounds {
        var value = OverlayBounds(point: a.point)
        value.lo = simd_min(value.lo, simd_min(b.point, c.point))
        value.hi = simd_max(value.hi, simd_max(b.point, c.point))
        return value
    }
}

struct OverlayBounds: Sendable {
    var lo: SIMD2<Double>
    var hi: SIMD2<Double>
    init(point: SIMD2<Double>) { lo = point; hi = point }
    init(_ points: [SIMD2<Double>]) {
        lo = points.first ?? .zero; hi = lo
        for p in points.dropFirst() { lo = simd_min(lo, p); hi = simd_max(hi, p) }
    }
    func intersects(_ other: Self) -> Bool {
        lo.x <= other.hi.x && hi.x >= other.lo.x && lo.y <= other.hi.y && hi.y >= other.lo.y
    }
    var epsilon: Double { max(1e-12, max(hi.x - lo.x, hi.y - lo.y) * 1e-10) }
}

enum OverlayMath {
    static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
    static func area(_ ring: [OverlayVertex]) -> Double {
        guard let origin = ring.first?.point else { return 0 }
        // Translate before multiplying to retain precision away from the origin.
        return ring.indices.reduce(0) { result, i in
            result + cross(ring[i].point - origin, ring[(i + 1) % ring.count].point - origin) / 2
        }
    }
    static func onSegment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, epsilon: Double) -> Bool {
        let delta = b - a
        return abs(cross(delta, p - a)) <= epsilon * max(simd_length(delta), epsilon)
            && p.x >= min(a.x, b.x) - epsilon && p.x <= max(a.x, b.x) + epsilon
            && p.y >= min(a.y, b.y) - epsilon && p.y <= max(a.y, b.y) + epsilon
    }
    enum Location { case outside, inside, boundary }
    static func locate(_ p: SIMD2<Double>, in ring: [OverlayVertex], epsilon: Double) -> Location {
        var inside = false
        for i in ring.indices {
            let a = ring[i].point, b = ring[(i + 1) % ring.count].point
            if onSegment(p, a, b, epsilon: epsilon) { return .boundary }
            if (a.y > p.y) != (b.y > p.y), p.x < a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y) {
                inside.toggle()
            }
        }
        return inside ? .inside : .outside
    }
    static func intersects(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>, epsilon: Double) -> Bool {
        if onSegment(a, c, d, epsilon: epsilon) || onSegment(b, c, d, epsilon: epsilon)
            || onSegment(c, a, b, epsilon: epsilon) || onSegment(d, a, b, epsilon: epsilon) { return true }
        let abC = cross(b - a, c - a), abD = cross(b - a, d - a)
        let cdA = cross(d - c, a - c), cdB = cross(d - c, b - c)
        return (abC > 0) != (abD > 0) && (cdA > 0) != (cdB > 0)
    }
    static func normalized(_ ring: [OverlayVertex], epsilon: Double) -> [OverlayVertex] {
        var result: [OverlayVertex] = []
        for p in ring where result.last.map({ simd_distance($0.point, p.point) > epsilon }) ?? true { result.append(p) }
        while result.count > 1, simd_distance(result[0].point, result[result.count - 1].point) <= epsilon { result.removeLast() }
        return result
    }
    static func appendTriangle(_ a: OverlayVertex, _ b: OverlayVertex, _ c: OverlayVertex,
                               epsilon: Double, to result: inout [OverlayTriangle], work: inout OverlayWork) throws {
        let area = cross(b.point - a.point, c.point - a.point)
        guard abs(area) > epsilon * epsilon else { return }
        try work.checkTriangles(result.count + 1)
        result.append(area < 0 ? .init(a: a, b: b, c: c) : .init(a: a, b: c, c: b))
    }
}
