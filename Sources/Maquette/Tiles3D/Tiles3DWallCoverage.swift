import RealityKit
import simd

/// Resolve coplanar skirts before publication. Photogrammetry can cut the same perimeter stretch
/// at several heights; independently extruding those cuts leaves overlapping, differently textured
/// faces. Sweep their planar arrangement so each covered point is drawn exactly once.
enum Tiles3DWallCoverage {
    private struct Line {
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        func height(_ x: Double) -> Double { a.y + (b.y - a.y) * ((x - a.x) / (b.x - a.x)) }
    }
    private struct Patch {
        var left: Double
        var right: Double
        var low: Line
        var high: Line
        var material: Int
    }

    static func resolve(_ input: Tiles3DShallowClosure.Geometry, prism: BoundaryPrism, earthDepth: Float, trayDepth: Float,
        limits: OverlayGeometryLimits = .init(maxTriangles: 50_000, maxOperations: 20_000_000)
    ) throws -> Tiles3DShallowClosure.Geometry {
        var work = try OverlayWork(limits)
        var groups: [Int: [Patch]] = [:]
        for part in input.parts {
            let first = part.indexOffset / MemoryLayout<UInt32>.stride
            for index in stride(from: first, to: first + part.indexCount, by: 6) {
                try work.spend(max(1, prism.boundary.edgeCount))
                let base = Int(input.mesh.indices[index])
                var a = input.mesh.vertices[base], bottomA = input.mesh.vertices[base + 1]
                var b = input.mesh.vertices[base + 2], bottomB = input.mesh.vertices[base + 3]
                guard let edge = prism.boundaryEdge(along: SIMD2(a.px, a.pz), SIMD2(b.px, b.pz)) else { continue }
                let (origin, end) = prism.boundary.edge(edge)
                let direction = simd_normalize(end - origin)
                func distance(_ p: Tiles3DVertex) -> Double {
                    Double(simd_dot(SIMD2(p.px, p.pz) - origin, direction))
                }
                var left = distance(a), right = distance(b)
                if left > right { swap(&a, &b); swap(&bottomA, &bottomB); swap(&left, &right) }
                guard right > left else { continue }
                groups[edge, default: []].append(Patch(left: left, right: right,
                    low: Line(a: SIMD2(left, Double(bottomA.py)), b: SIMD2(right, Double(bottomB.py))),
                    high: Line(a: SIMD2(left, Double(a.py)), b: SIMD2(right, Double(b.py))),
                    material: part.materialIndex))
            }
        }
        var meshes: [Int: Tiles3DCutWall.Geometry] = [:]
        for edge in groups.keys.sorted() {
            let source = groups[edge]!
            try work.spend(source.count * max(1, Int(log2(Double(max(2, source.count))))))
            let patches = source.sorted { $0.left < $1.left }
            var cuts = Set(patches.flatMap { [$0.left, $0.right] })
            var active: [Patch] = []
            for patch in patches {
                active.removeAll { $0.right <= patch.left }
                for other in active {
                    try work.spend(4)
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
            for i in 1..<xs.count {
                let left = xs[i - 1], right = xs[i], middle = left + (right - left) / 2
                guard right > left else { continue }
                active.removeAll { $0.right <= left }
                while next < patches.count, patches[next].left <= left {
                    if patches[next].right >= right { active.append(patches[next]) }
                    next += 1
                }
                try work.spend(active.count * max(1, Int(log2(Double(max(2, active.count))))) * 4)
                struct Interval { var low: Line; var high: Line }
                func merged(material: Int) -> [Interval] {
                    let intervals = active.filter { $0.material == material }.map { Interval(low: $0.low, high: $0.high) }
                        .sorted { $0.low.height(middle) < $1.low.height(middle) }
                    var result: [Interval] = []
                    for interval in intervals {
                        if let last = result.last, interval.low.height(middle) <= last.high.height(middle) {
                            if interval.high.height(middle) > last.high.height(middle) {
                                result[result.count - 1].high = interval.high
                            }
                        } else { result.append(interval) }
                    }
                    return result
                }
                let earth = merged(material: 0), tray = merged(material: 1)
                var regions = earth.map { ($0, 0) }
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
                for (region, material) in regions {
                    try work.spend()
                    guard region.high.height(middle) - region.low.height(middle) > 1e-10 else { continue }
                    let (origin, end) = prism.boundary.edge(edge)
                    let direction = simd_normalize(end - origin)
                    let normal = DioramaBoundary.outwardNormal(forEdgeFrom: origin, to: end)
                    let depth = material == 0 ? earthDepth : trayDepth
                    let repeatU = max(1, (prism.perimeter / depth).rounded())
                    func vertex(_ x: Double, _ y: Double) -> Tiles3DVertex {
                        let point = origin + direction * Float(x)
                        let u = prism.perimeterPosition(of: point, onEdge: edge) * repeatU
                        return .init(position: SIMD3(point.x, Float(y), point.y), normal: normal,
                            uv: SIMD2(u, Float(y) / depth))
                    }
                    let vertices = [vertex(left, region.high.height(left)), vertex(left, region.low.height(left)),
                        vertex(right, region.high.height(right)), vertex(right, region.low.height(right))]
                    try work.checkTriangles(meshes.values.reduce(0) { $0 + $1.indices.count / 3 } + 2)
                    append(vertices, to: &meshes[material, default: .init()])
                }
            }
        }
        var result = Tiles3DShallowClosure.Geometry()
        for material in meshes.keys.sorted() {
            let mesh = meshes[material]!
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
