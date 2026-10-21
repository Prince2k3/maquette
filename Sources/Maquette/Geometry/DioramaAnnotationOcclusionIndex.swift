import simd

/// Immutable, double-sided triangle acceleration structure for annotation sight lines.
/// Segment endpoints are inset by a physical tolerance so a label's own ground is not an occluder.
struct DioramaAnnotationOcclusionIndex: Sendable {
    private struct Bounds: Sendable {
        var minimum: SIMD3<Float>
        var maximum: SIMD3<Float>

        func intersects(origin: SIMD3<Float>, direction: SIMD3<Float>, distance: Float) -> Bool {
            var near: Float = 0
            var far = distance
            for axis in 0..<3 {
                if direction[axis] == 0 {
                    if origin[axis] < minimum[axis] || origin[axis] > maximum[axis] { return false }
                } else {
                    let a = (minimum[axis] - origin[axis]) / direction[axis]
                    let b = (maximum[axis] - origin[axis]) / direction[axis]
                    near = max(near, min(a, b))
                    far = min(far, max(a, b))
                    if near > far { return false }
                }
            }
            return true
        }
    }

    private struct Triangle: Sendable {
        let sourceA: Int
        let sourceB: Int
        let sourceC: Int
        let a: SIMD3<Float>
        let ab: SIMD3<Float>
        let ac: SIMD3<Float>
        let normalLength: Float
        let bounds: Bounds
        let centroid: SIMD3<Float>

        func intersects(origin: SIMD3<Float>, direction: SIMD3<Float>, near: Float, far: Float) -> Bool {
            Self.intersects(a: a, ab: ab, ac: ac, normalLength: normalLength,
                            origin: origin, direction: direction, near: near, far: far)
        }

        func intersects(positions: [SIMD3<Float>], origin: SIMD3<Float>, direction: SIMD3<Float>, near: Float, far: Float) -> Bool {
            guard sourceA < positions.count, sourceB < positions.count, sourceC < positions.count else { return false }
            let a = positions[sourceA], b = positions[sourceB], c = positions[sourceC]
            guard DioramaAnnotationOcclusionIndex.finite(a),
                  DioramaAnnotationOcclusionIndex.finite(b),
                  DioramaAnnotationOcclusionIndex.finite(c) else { return false }
            let ab = b - a, ac = c - a
            let normalLength = simd_length(simd_cross(ab, ac))
            guard normalLength.isFinite, normalLength > 0 else { return false }
            return Self.intersects(a: a, ab: ab, ac: ac, normalLength: normalLength,
                                   origin: origin, direction: direction, near: near, far: far)
        }

        private static func intersects(a: SIMD3<Float>, ab: SIMD3<Float>, ac: SIMD3<Float>, normalLength: Float,
                                       origin: SIMD3<Float>, direction: SIMD3<Float>, near: Float, far: Float) -> Bool {
            let p = simd_cross(direction, ac)
            let determinant = simd_dot(ab, p)
            // Relative to triangle area: very small physical meshes retain their intersections.
            guard abs(determinant) > normalLength * 1e-7 else { return false }
            let inverse = 1 / determinant
            let offset = origin - a
            let u = simd_dot(offset, p) * inverse
            guard u >= -1e-6, u <= 1 + 1e-6 else { return false }
            let q = simd_cross(offset, ab)
            let v = simd_dot(direction, q) * inverse
            guard v >= -1e-6, u + v <= 1 + 1e-6 else { return false }
            let distance = simd_dot(ac, q) * inverse
            return distance > near && distance < far
        }
    }

    private struct Node: Sendable {
        let bounds: Bounds
        var start: Int
        var count: Int
        var left: Int = -1
        var right: Int = -1
    }

    private let triangles: [Triangle]
    private let nodes: [Node]

    /// Dynamic heights keep conservative vertical bounds and partition only the fixed X/Z topology.
    /// Pass current vertex positions to `occludes(from:to:positions:tolerance:)` after a ground pan.
    init(positions: [SIMD3<Float>], indices: [UInt32], dynamicHeights: Bool = false) {
        var triangles: [Triangle] = []
        triangles.reserveCapacity(indices.count / 3)
        for index in stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            if index.isMultiple(of: 768), Task<Never, Never>.isCancelled { break }
            let ia = Int(indices[index])
            let ib = Int(indices[index + 1])
            let ic = Int(indices[index + 2])
            guard ia < positions.count, ib < positions.count, ic < positions.count else { continue }
            let a = positions[ia], b = positions[ib], c = positions[ic]
            guard Self.finite(a), Self.finite(b), Self.finite(c) else { continue }
            let ab = b - a, ac = c - a
            let normalLength = simd_length(simd_cross(ab, ac))
            guard normalLength.isFinite, dynamicHeights || normalLength > 0 else { continue }
            let centroid = a / 3 + b / 3 + c / 3
            guard Self.finite(centroid) else { continue }
            triangles.append(Triangle(
                sourceA: ia, sourceB: ib, sourceC: ic,
                a: a, ab: ab, ac: ac, normalLength: normalLength,
                bounds: Bounds(minimum: simd_min(a, simd_min(b, c)), maximum: simd_max(a, simd_max(b, c))),
                centroid: centroid
            ))
        }
        var nodes: [Node] = []
        if !triangles.isEmpty, !Task<Never, Never>.isCancelled {
            nodes.reserveCapacity(triangles.count / 2)
            let range = triangles.indices
            _ = Self.build(triangles: &triangles, range: range, nodes: &nodes, dynamicHeights: dynamicHeights)
        }
        // A cancelled build is never published as a partially indexed mesh.
        self.triangles = Task<Never, Never>.isCancelled ? [] : triangles
        self.nodes = Task<Never, Never>.isCancelled ? [] : nodes
    }

    /// Returns whether any triangle intersects the sight line before the target, in either winding.
    func occludes(from origin: SIMD3<Float>, to target: SIMD3<Float>, tolerance: Float = 0.0001) -> Bool {
        intersectsSegment(from: origin, to: target, positions: nil, tolerance: tolerance)
    }

    /// Tests current heights without rebuilding the BVH. Vertex count/order and X/Z must match
    /// the topology supplied to `init(dynamicHeights: true)`; malformed current triangles are skipped.
    func occludes(from origin: SIMD3<Float>, to target: SIMD3<Float>, positions: [SIMD3<Float>],
                  tolerance: Float = 0.0001) -> Bool {
        intersectsSegment(from: origin, to: target, positions: positions, tolerance: tolerance)
    }

    private func intersectsSegment(from origin: SIMD3<Float>, to target: SIMD3<Float>,
                                   positions: [SIMD3<Float>]?, tolerance: Float) -> Bool {
        guard !nodes.isEmpty, Self.finite(origin), Self.finite(target), tolerance.isFinite else { return false }
        let delta = target - origin
        let length = simd_length(delta)
        let near = max(0, tolerance)
        let far = length - near
        guard length.isFinite, length > 0, far > near else { return false }
        let direction = delta / length
        var pending = [0]
        while let index = pending.popLast() {
            let node = nodes[index]
            guard node.bounds.intersects(origin: origin, direction: direction, distance: far) else { continue }
            if node.count > 0 {
                for triangle in triangles[node.start..<(node.start + node.count)] {
                    let hit: Bool
                    if let positions {
                        hit = triangle.intersects(positions: positions, origin: origin, direction: direction, near: near, far: far)
                    } else {
                        hit = triangle.intersects(origin: origin, direction: direction, near: near, far: far)
                    }
                    if hit { return true }
                }
            } else {
                pending.append(node.left)
                pending.append(node.right)
            }
        }
        return false
    }

    private static func finite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func build(triangles: inout [Triangle], range: Range<Int>, nodes: inout [Node], dynamicHeights: Bool) -> Int {
        guard !Task<Never, Never>.isCancelled else { return -1 }
        var bounds = triangles[range.lowerBound].bounds
        var centroidMin = triangles[range.lowerBound].centroid
        var centroidMax = centroidMin
        for offset in range {
            if offset.isMultiple(of: 1024), Task<Never, Never>.isCancelled { return -1 }
            let triangle = triangles[offset]
            bounds.minimum = simd_min(bounds.minimum, triangle.bounds.minimum)
            bounds.maximum = simd_max(bounds.maximum, triangle.bounds.maximum)
            centroidMin = simd_min(centroidMin, triangle.centroid)
            centroidMax = simd_max(centroidMax, triangle.centroid)
        }
        if dynamicHeights {
            bounds.minimum.y = -Float.greatestFiniteMagnitude
            bounds.maximum.y = Float.greatestFiniteMagnitude
        }
        let index = nodes.count
        nodes.append(Node(bounds: bounds, start: range.lowerBound, count: range.count))
        guard range.count > 8 else { return index }
        let extent = centroidMax - centroidMin
        let axis = dynamicHeights ? (extent.x >= extent.z ? 0 : 2)
            : (extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2))
        guard extent[axis] > 0 else { return index }
        let sorted = triangles[range].sorted { $0.centroid[axis] < $1.centroid[axis] }
        triangles.replaceSubrange(range, with: sorted)
        let middle = range.lowerBound + range.count / 2
        let left = build(triangles: &triangles, range: range.lowerBound..<middle, nodes: &nodes, dynamicHeights: dynamicHeights)
        let right = build(triangles: &triangles, range: middle..<range.upperBound, nodes: &nodes, dynamicHeights: dynamicHeights)
        nodes[index].count = 0
        nodes[index].left = left
        nodes[index].right = right
        return index
    }
}
