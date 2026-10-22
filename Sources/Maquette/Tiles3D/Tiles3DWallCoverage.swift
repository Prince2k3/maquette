import RealityKit
import simd

/// Resolve coplanar skirts before publication. Photogrammetry can cut the same perimeter stretch
/// at several heights; independently extruding those cuts leaves overlapping, differently textured
/// faces. Sweep their planar arrangement so each covered point is drawn exactly once.
enum Tiles3DWallCoverage {
    private struct Line {
        let originX: Double
        let originY: Double
        let slope: Double
        init(a: SIMD2<Double>, b: SIMD2<Double>) {
            originX = a.x; originY = a.y
            slope = (b.y - a.y) / (b.x - a.x)
        }
        func height(_ x: Double) -> Double { originY + slope * (x - originX) }
    }
    private struct Patch {
        var left: Double
        var right: Double
        var low: Line
        var high: Line
        var material: Int
        var source: Int
    }

    private struct EdgeFrame {
        let origin: SIMD2<Float>
        let direction: SIMD2<Float>
        let length: Float
        let normal: SIMD3<Float>
        func distance(to point: SIMD2<Float>) -> Float {
            let along = min(max(simd_dot(point - origin, direction), 0), length)
            return simd_distance(point, origin + direction * along)
        }
    }

    static func resolve(edges: [Tiles3DCutEdge], lowestY: Float, prism: BoundaryPrism,
        earthDepth: Float, trayDepth: Float, includesWalls: Bool,
        limits: OverlayGeometryLimits = .init(maxTriangles: 50_000, maxOperations: 20_000_000)
    ) throws -> Tiles3DShallowClosure.Geometry {
        var work = try OverlayWork(limits)
        var groups = Array(repeating: [Patch](), count: prism.boundary.edgeCount)
        let cap = ChunkThicknessLimit.maximum(for: prism.boundary)
        let tolerance = prism.cutEdgeTolerance
        let frames = prism.boundary.vertices.indices.map { index in
            let (a, b) = prism.boundary.edge(index)
            let length = simd_distance(a, b)
            return EdgeFrame(origin: a, direction: length > 0 ? (b - a) / length : .zero,
                length: length, normal: DioramaBoundary.outwardNormal(forEdgeFrom: a, to: b))
        }
        for (sourceID, edge) in edges.enumerated() {
            try work.spend(3)
            guard prism.boundary.vertices.indices.contains(edge.boundaryEdge) else { continue }
            let frame = frames[edge.boundaryEdge]
            let a = SIMD2(edge.a.x, edge.a.z), b = SIMD2(edge.b.x, edge.b.z)
            // The clipper already carries the boundary-edge identity. Validate that edge in
            // constant time, including the midpoint so an interior chord cannot become a wall.
            guard frame.length > 0, simd_distance(a, b) > tolerance,
                  frame.distance(to: a) <= tolerance,
                  frame.distance(to: b) <= tolerance,
                  frame.distance(to: (a + b) / 2) <= tolerance else { continue }
            var left = Double(simd_dot(a - frame.origin, frame.direction))
            var right = Double(simd_dot(b - frame.origin, frame.direction))
            var topA = edge.a.y, topB = edge.b.y
            if left > right { swap(&left, &right); swap(&topA, &topB) }
            guard right > left else { continue }
            func append(shift: Float, depth: Float, material: Int) {
                let limit = min(depth, cap), floor = lowestY - shift - depth
                let a = topA - shift, b = topB - shift
                guard limit.isFinite, limit > 0, max(a, b) > floor else { return }
                groups[edge.boundaryEdge].append(Patch(left: left, right: right,
                    low: Line(a: SIMD2(left, Double(max(floor, a - limit))), b: SIMD2(right, Double(max(floor, b - limit)))),
                    high: Line(a: SIMD2(left, Double(max(floor, a))), b: SIMD2(right, Double(max(floor, b)))),
                    material: material, source: sourceID))
            }
            if includesWalls { append(shift: 0, depth: earthDepth, material: 0) }
            if trayDepth > 0 { append(shift: earthDepth, depth: trayDepth, material: 1) }
        }
        var meshes = [Tiles3DCutWall.Geometry(), Tiles3DCutWall.Geometry()]
        for edge in groups.indices where !groups[edge].isEmpty {
            let source = groups[edge]
            let frame = frames[edge]
            let repeatU = [earthDepth, trayDepth].map { $0 > 0 ? max(1, (prism.perimeter / $0).rounded()) : 1 }
            try work.spend(source.count * max(1, Int(log2(Double(max(2, source.count))))))
            let patches = source.sorted { $0.left < $1.left }
            var cuts = Set<Double>()
            cuts.reserveCapacity(source.count)
            var lastSource = -1
            for patch in source where patch.source != lastSource {
                cuts.insert(patch.left); cuts.insert(patch.right)
                lastSource = patch.source
            }
            var active: [Patch] = []
            for patch in patches {
                active.removeAll { $0.right <= patch.left }
                for other in active {
                    try work.spend(4)
                    // Earth ends at or above its own tray; they never intersect each other.
                    if patch.source == other.source { continue }
                    let left = max(patch.left, other.left), right = min(patch.right, other.right)
                    guard max(patch.high.height(left), patch.high.height(right)) >= min(other.low.height(left), other.low.height(right)),
                          max(other.high.height(left), other.high.height(right)) >= min(patch.low.height(left), patch.low.height(right)) else { continue }
                    for a in [patch.low, patch.high] {
                        for b in [other.low, other.high] {
                            let dl = a.height(left) - b.height(left)
                            let dr = a.height(right) - b.height(right)
                            if dl * dr < 0 { cuts.insert(left + (right - left) * dl / (dl - dr)) }
                        }
                    }
                }
                active.append(patch)
            }
            try work.spend(cuts.count * max(1, Int(log2(Double(max(2, cuts.count))))))
            let xs = cuts.sorted()
            active = []
            var next = 0
            struct Interval { var low: Line; var high: Line }
            var earth: [Interval] = [], tray: [Interval] = []
            var regions: [(Interval, Int)] = []
            func merge(material: Int, into result: inout [Interval], at x: Double) {
                result.removeAll(keepingCapacity: true)
                for patch in active where patch.material == material {
                    result.append(Interval(low: patch.low, high: patch.high))
                }
                result.sort { $0.low.height(x) < $1.low.height(x) }
                var count = 0
                for index in result.indices {
                    let interval = result[index]
                    if count > 0, interval.low.height(x) <= result[count - 1].high.height(x) {
                        if interval.high.height(x) > result[count - 1].high.height(x) { result[count - 1].high = interval.high }
                    } else { result[count] = interval; count += 1 }
                }
                result.removeLast(result.count - count)
            }
            for i in 1..<xs.count {
                let left = xs[i - 1], right = xs[i], middle = left + (right - left) / 2
                guard right > left else { continue }
                active.removeAll { $0.right <= left }
                while next < patches.count, patches[next].left <= left {
                    if patches[next].right >= right { active.append(patches[next]) }
                    next += 1
                }
                try work.spend(active.count * max(1, Int(log2(Double(max(2, active.count))))) * 4)
                regions.removeAll(keepingCapacity: true)
                if active.count == 1 || (active.count == 2 && active[0].source == active[1].source) {
                    // A single source cut's earth/tray bands are disjoint by construction.
                    // Preserve them directly; only genuinely overlapping cuts need a union.
                    for patch in active { regions.append((Interval(low: patch.low, high: patch.high), patch.material)) }
                } else {
                    merge(material: 0, into: &earth, at: middle)
                    merge(material: 1, into: &tray, at: middle)
                    for interval in earth { regions.append((interval, 0)) }
                    // Subtract the earth union from the tray union with one forward scan. Both sets
                    // are disjoint and sorted vertically, so ownership work is linear per slab.
                    var cursor = 0
                    for interval in tray {
                        var low = interval.low
                        while cursor < earth.count, earth[cursor].high.height(middle) <= low.height(middle) { cursor += 1 }
                        var index = cursor
                        while index < earth.count, earth[index].low.height(middle) < interval.high.height(middle) {
                            if earth[index].low.height(middle) > low.height(middle) {
                                regions.append((Interval(low: low, high: earth[index].low), 1))
                            }
                            if earth[index].high.height(middle) > low.height(middle) { low = earth[index].high }
                            if low.height(middle) >= interval.high.height(middle) { break }
                            index += 1
                        }
                        if low.height(middle) < interval.high.height(middle) {
                            regions.append((Interval(low: low, high: interval.high), 1))
                        }
                    }
                }
                for (region, material) in regions {
                    try work.spend()
                    guard region.high.height(middle) - region.low.height(middle) > 1e-10 else { continue }
                    let depth = material == 0 ? earthDepth : trayDepth
                    func vertex(_ x: Double, _ y: Double) -> Tiles3DVertex {
                        let along = min(max(Float(x), 0), frame.length)
                        let point = frame.origin + frame.direction * Float(x)
                        let u = min(max((prism.cumulativeEdgeLengths[edge] + along) / prism.perimeter, 0), 1) * repeatU[material]
                        return .init(position: SIMD3(point.x, Float(y), point.y), normal: frame.normal,
                            uv: SIMD2(u, Float(y) / depth))
                    }
                    let vertices = [vertex(left, region.high.height(left)), vertex(left, region.low.height(left)),
                        vertex(right, region.high.height(right)), vertex(right, region.low.height(right))]
                    try work.checkTriangles(meshes.reduce(0) { $0 + $1.indices.count / 3 } + 2)
                    append(vertices, to: &meshes[material])
                }
            }
        }
        var result = Tiles3DShallowClosure.Geometry()
        for material in meshes.indices where !meshes[material].isEmpty {
            let mesh = meshes[material]
            let offset = UInt32(result.mesh.vertices.count)
            result.parts.append(.init(indexOffset: result.mesh.indices.count * MemoryLayout<UInt32>.stride,
                indexCount: mesh.indices.count, materialIndex: material, bounds: mesh.bounds))
            result.mesh.vertices.append(contentsOf: mesh.vertices)
            result.mesh.indices.append(contentsOf: mesh.indices.map { $0 + offset })
            result.mesh.lower = simd_min(result.mesh.lower, mesh.lower)
            result.mesh.upper = simd_max(result.mesh.upper, mesh.upper)
        }
        return result
    }
    private static func append(_ vertices: [Tiles3DVertex], to mesh: inout Tiles3DCutWall.Geometry) {
        let base = UInt32(mesh.vertices.count)
        mesh.vertices.append(contentsOf: vertices)
        mesh.indices.append(contentsOf: [base, base + 1, base + 3, base, base + 3, base + 2])
        for vertex in vertices {
            mesh.lower = simd_min(mesh.lower, vertex.position)
            mesh.upper = simd_max(mesh.upper, vertex.position)
        }
    }

}
