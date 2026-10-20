import simd

struct OverlayLineSample: Sendable {
    var vertex: OverlayVertex
    /// Distance along the original, unclipped planar path; gaps never reset dash phase.
    var distance: Double
}

enum OverlayLineClipper {
    static func clip(_ path: [OverlayVertex], boundary: [OverlayVertex],
                     limits: OverlayGeometryLimits = .init()) throws -> [[OverlayLineSample]] {
        var work = try OverlayWork(limits)
        let ring = try OverlayPolygonTessellator.validated([boundary], work: &work)[0]
        guard path.count <= limits.maxInputVertices else { throw OverlayGeometryError.budgetExceeded }
        guard path.allSatisfy(\.isFinite) else { throw OverlayGeometryError.nonFiniteInput }
        guard path.count > 1 else { return [] }
        let epsilon = OverlayBounds(ring.map(\.point)).epsilon
        var runs: [[OverlayLineSample]] = []
        var distance = 0.0
        var segments = 0
        for index in 1..<path.count {
            let a = path[index - 1], b = path[index], delta = b.point - a.point
            let length = simd_length(delta)
            guard length.isFinite else { throw OverlayGeometryError.nonFiniteInput }
            guard length > epsilon else { continue }
            let parameterEpsilon = epsilon / length
            var cuts = [0.0, 1.0]
            for edge in ring.indices {
                try work.spend()
                let c = ring[edge].point, d = ring[(edge + 1) % ring.count].point, side = d - c
                let denominator = OverlayMath.cross(delta, side)
                if abs(denominator) > epsilon * max(length, simd_length(side)) {
                    let t = OverlayMath.cross(c - a.point, side) / denominator
                    let u = OverlayMath.cross(c - a.point, delta) / denominator
                    if t >= -parameterEpsilon, t <= 1 + parameterEpsilon,
                       u >= -epsilon / simd_length(side), u <= 1 + epsilon / simd_length(side) {
                        cuts.append(min(1, max(0, t)))
                    }
                } else if abs(OverlayMath.cross(delta, c - a.point)) <= epsilon * length {
                    // Collinear overlap contributes its endpoints, not an arbitrary crossing.
                    for point in [c, d] {
                        let t = simd_dot(point - a.point, delta) / (length * length)
                        if t >= 0, t <= 1 { cuts.append(t) }
                    }
                }
            }
            cuts.sort()
            var unique: [Double] = []
            for cut in cuts where unique.last.map({ cut - $0 > parameterEpsilon }) ?? true { unique.append(cut) }
            for i in 1..<unique.count {
                let start = unique[i - 1], end = unique[i]
                try work.spend(ring.count)
                let middle = a.point + delta * ((start + end) / 2)
                guard OverlayMath.locate(middle, in: ring, epsilon: epsilon) != .outside else { continue }
                segments += 1
                try work.checkTriangles(segments)
                let first = OverlayLineSample(vertex: a.interpolated(to: b, at: start), distance: distance + start * length)
                let last = OverlayLineSample(vertex: a.interpolated(to: b, at: end), distance: distance + end * length)
                if let previous = runs.last?.last, abs(previous.distance - first.distance) <= epsilon,
                   simd_distance(previous.vertex.point, first.vertex.point) <= epsilon {
                    runs[runs.count - 1].append(last)
                } else {
                    runs.append([first, last])
                }
            }
            distance += length
        }
        return runs
    }
}

/// A basic butt-capped ribbon footprint. Styled caps/joins/dashes are a phase-3 concern.
/// The footprint is expanded *before* clipping, so a wide line cannot overhang the outline.
enum OverlayStrokeGeometry {
    static func build(_ input: [OverlayVertex], width: Double, boundary: [OverlayVertex],
                      limits: OverlayGeometryLimits = .init()) throws -> [OverlayTriangle] {
        guard width.isFinite, width > 0 else { throw OverlayGeometryError.invalidWidth }
        guard input.count <= limits.maxInputVertices else { throw OverlayGeometryError.budgetExceeded }
        guard input.allSatisfy(\.isFinite) else { throw OverlayGeometryError.nonFiniteInput }
        let epsilon = OverlayBounds(input.map(\.point)).epsilon
        var path: [OverlayVertex] = []
        for vertex in input where path.last.map({ simd_distance($0.point, vertex.point) > epsilon }) ?? true { path.append(vertex) }
        guard path.count >= 2 else { return [] }
        var work = try OverlayWork(limits)
        var distances = [0.0]
        var ranges: [(start: Int, end: Int)] = []
        var start = 0
        for i in 1..<path.count {
            try work.spend()
            distances.append(distances[i - 1] + simd_distance(path[i - 1].point, path[i].point))
            if i < path.count - 1 {
                let incoming = simd_normalize(path[i].point - path[i - 1].point)
                let outgoing = simd_normalize(path[i + 1].point - path[i].point)
                if simd_length(incoming + outgoing) <= 1e-10 {
                    ranges.append((start, i)); start = i
                }
            }
        }
        ranges.append((start, path.count - 1))
        var footprint: [OverlayTriangle] = []
        // Split reversals into butt-ended strips rather than normalizing a zero tangent.
        for range in ranges {
            var edges: [(left: OverlayVertex, right: OverlayVertex)] = []
            for i in range.start...range.end {
                try work.spend()
                let incoming = i > range.start ? simd_normalize(path[i].point - path[i - 1].point)
                    : simd_normalize(path[i + 1].point - path[i].point)
                let outgoing = i < range.end ? simd_normalize(path[i + 1].point - path[i].point) : incoming
                let direction = simd_normalize(incoming + outgoing), normal = SIMD2(-direction.y, direction.x)
                let denominator = simd_dot(normal, SIMD2(-incoming.y, incoming.x))
                let offset = normal * min(width * 2, width / (2 * max(denominator, 1e-10)))
                var left = path[i], right = path[i]
                left.point += offset; right.point -= offset
                left.uv = SIMD2(0, distances[i]); right.uv = SIMD2(1, distances[i])
                guard left.isFinite, right.isFinite else { throw OverlayGeometryError.nonFiniteInput }
                edges.append((left, right))
            }
            for i in 1..<edges.count {
                try OverlayMath.appendTriangle(edges[i - 1].left, edges[i].left, edges[i - 1].right,
                                               epsilon: epsilon, to: &footprint, work: &work)
                try OverlayMath.appendTriangle(edges[i - 1].right, edges[i].left, edges[i].right,
                                               epsilon: epsilon, to: &footprint, work: &work)
            }
        }
        return try OverlayAreaGeometry.clip(footprint, boundary: boundary, work: &work)
    }
}
