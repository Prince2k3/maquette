import Foundation
import simd

enum OverlayStyledStroke {
    private struct Point {
        var vertex: OverlayVertex
        var width: Double
        var distance: Double
        func interpolated(to b: Self, at t: Double) -> Self {
            .init(vertex: vertex.interpolated(to: b.vertex, at: t), width: width + (b.width - width) * t,
                  distance: distance + (b.distance - distance) * t)
        }
    }
    static func build(_ path: [OverlayVertex], widths: [Double], distances: [Double], style: DioramaStrokeStyle,
                      closed: Bool = false, boundary: [OverlayVertex], limits: OverlayGeometryLimits = .init()) throws -> [OverlayTriangle] {
        var work = try OverlayWork(limits)
        guard path.count == widths.count, path.count == distances.count, path.count <= limits.maxInputVertices,
              path.allSatisfy(\.isFinite), widths.allSatisfy({ $0.isFinite && $0 > 0 }),
              distances.allSatisfy(\.isFinite), style.dashPhase.isFinite,
              style.miterLimit.isFinite, style.miterLimit >= 1,
              style.dash.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw OverlayGeometryError.invalidWidth }
        guard path.count > 1 else { return [] }
        var points: [Point] = []
        for i in path.indices {
            if i > 0, distances[i] < distances[i - 1] { throw OverlayGeometryError.invalidWidth }
            if let last = points.last, simd_distance(last.vertex.point, path[i].point) < 1e-12 { continue }
            points.append(.init(vertex: path[i], width: widths[i], distance: distances[i]))
        }
        guard points.count > 1 else { return [] }
        var pattern = style.dash
        if !pattern.count.isMultiple(of: 2) { pattern += pattern }
        let period = pattern.reduce(0, +)
        guard period.isFinite else { throw OverlayGeometryError.invalidWidth }
        var runs: [[Point]] = []
        if pattern.isEmpty { runs = [points] }
        else {
            for i in 1..<points.count {
                let a = points[i - 1], b = points[i], length = b.distance - a.distance
                guard length > 0 else { continue }
                var progress = 0.0
                while progress < length {
                    try work.spend()
                    var phase = (a.distance + progress + style.dashPhase).truncatingRemainder(dividingBy: period)
                    if phase < 0 { phase += period }
                    var part = 0
                    while part < pattern.count - 1, phase >= pattern[part] { phase -= pattern[part]; part += 1 }
                    let step = min(length - progress, pattern[part] - phase)
                    guard step > 0, progress + step > progress else { throw OverlayGeometryError.invalidWidth }
                    if part.isMultiple(of: 2) {
                        let first = a.interpolated(to: b, at: progress / length)
                        let last = a.interpolated(to: b, at: (progress + step) / length)
                        if let previous = runs.last?.last, abs(previous.distance - first.distance) < 1e-10 {
                            runs[runs.count - 1].append(last)
                        } else { runs.append([first, last]) }
                    }
                    progress += step
                }
            }
        }
        if closed, runs.count > 1, let first = runs.first?.first, let last = runs.last?.last,
           simd_distance(first.vertex.point, last.vertex.point) < 1e-10 {
            let tail = runs.removeLast()
            runs[0] = tail + runs[0].dropFirst()
        }
        var patches: [[OverlayVertex]] = []
        func moved(_ p: Point, _ offset: SIMD2<Double>) -> OverlayVertex { var v = p.vertex; v.point += offset; return v }
        func sector(_ p: Point, from start: SIMD2<Double>, sweep: Double) {
            let count = max(1, Int(ceil(abs(sweep) / (.pi / 32))))
            let angle = atan2(start.y, start.x), radius = simd_length(start)
            var ring = [p.vertex]
            for i in 0...count {
                let a = angle + sweep * Double(i) / Double(count)
                ring.append(moved(p, SIMD2(cos(a), sin(a)) * radius))
            }
            patches.append(ring)
        }
        for run in runs {
            let loop = closed && simd_distance(run[0].vertex.point, run[run.count - 1].vertex.point) < 1e-10
            for i in 1..<run.count {
                try work.spend()
                var a = run[i - 1], b = run[i]
                let direction = simd_normalize(b.vertex.point - a.vertex.point), normal = SIMD2(-direction.y, direction.x)
                if !loop, style.lineCap == .square {
                    if i == 1 { a.vertex.point -= direction * (a.width / 2) }
                    if i == run.count - 1 { b.vertex.point += direction * (b.width / 2) }
                }
                patches.append([moved(a, normal * (a.width / 2)), moved(b, normal * (b.width / 2)),
                                moved(b, -normal * (b.width / 2)), moved(a, -normal * (a.width / 2))])
            }
            let lastUnique = loop ? run.count - 2 : run.count - 1
            if lastUnique >= 1 {
                for i in (loop ? 0 : 1)...lastUnique where loop || i < lastUnique {
                    try work.spend()
                    let p = run[i], before = run[i == 0 ? lastUnique : i - 1], after = run[i == lastUnique ? 0 : i + 1]
                    let incoming = simd_normalize(p.vertex.point - before.vertex.point), outgoing = simd_normalize(after.vertex.point - p.vertex.point)
                    let turn = OverlayMath.cross(incoming, outgoing)
                    guard abs(turn) > 1e-10 else { continue }
                    let sign = turn > 0 ? -1.0 : 1.0
                    let a = SIMD2(-incoming.y, incoming.x) * (sign * p.width / 2)
                    let b = SIMD2(-outgoing.y, outgoing.x) * (sign * p.width / 2)
                    if style.lineJoin == .round {
                        sector(p, from: a, sweep: atan2(OverlayMath.cross(a, b), simd_dot(a, b)))
                    } else {
                        let miter = a + incoming * (OverlayMath.cross(b - a, outgoing) / turn)
                        if style.lineJoin == .miter, simd_length(miter) <= style.miterLimit * p.width / 2 {
                            patches.append([p.vertex, moved(p, a), moved(p, miter), moved(p, b)])
                        } else { patches.append([p.vertex, moved(p, a), moved(p, b)]) }
                    }
                }
            }
            if !loop, style.lineCap == .round {
                let first = run[0], last = run[run.count - 1]
                let a = simd_normalize(run[1].vertex.point - first.vertex.point)
                let b = simd_normalize(last.vertex.point - run[run.count - 2].vertex.point)
                sector(first, from: SIMD2(-a.y, a.x) * (first.width / 2), sweep: .pi)
                sector(last, from: SIMD2(b.y, -b.x) * (last.width / 2), sweep: .pi)
            }
        }
        let merged = try OverlayRegionUnion.triangulate(patches, work: &work)
        return try OverlayAreaGeometry.clip(merged, boundary: boundary, work: &work)
    }
}
