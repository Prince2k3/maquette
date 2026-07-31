import Foundation
import RealityKit
import simd

/// Generates flat ribbon meshes from 3D point sequences for rendering polylines on the diorama surface.
enum PolylineMeshGenerator {
    /// Generates a flat ribbon mesh from a sequence of 3D points.
    ///
    /// The ribbon lies in the XZ plane with a Y offset above the terrain to stay visible.
    /// Each segment has 2 vertices (left/right) perpendicular to the path direction.
    ///
    /// - Parameters:
    ///   - points: 3D positions along the polyline path (minimum 2 required).
    ///   - width: The width of the ribbon in diorama-space meters.
    ///   - yOffset: Vertical offset above the terrain-sampled Y to prevent z-fighting. Defaults to `0.005`.
    /// - Returns: A `MeshResource` representing the ribbon.
    @MainActor
    public static func generateMesh(
        from points: [SIMD3<Float>],
        width: Float,
        yOffset: Float = 0.005
    ) throws -> MeshResource {
        guard points.count >= 2 else {
            throw DioramaError.meshGenerationFailed(reason: "Polyline requires at least 2 points")
        }

        let halfWidth = width / 2.0
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        positions.reserveCapacity(points.count * 2)
        normals.reserveCapacity(points.count * 2)
        uvs.reserveCapacity(points.count * 2)

        let totalLength = cumulativeLengths(points)

        for i in 0..<points.count {
            let point = points[i]

            // Compute direction in the XZ plane
            let direction: SIMD2<Float>
            if i == 0 {
                // First point: use forward direction
                let next = points[i + 1]
                direction = simd_normalize(SIMD2<Float>(next.x - point.x, next.z - point.z))
            } else if i == points.count - 1 {
                // Last point: use backward direction
                let prev = points[i - 1]
                direction = simd_normalize(SIMD2<Float>(point.x - prev.x, point.z - prev.z))
            } else {
                // Middle point: average of incoming and outgoing directions
                let prev = points[i - 1]
                let next = points[i + 1]
                let d1 = simd_normalize(SIMD2<Float>(point.x - prev.x, point.z - prev.z))
                let d2 = simd_normalize(SIMD2<Float>(next.x - point.x, next.z - point.z))
                let avg = d1 + d2
                let len = simd_length(avg)
                direction = len > 0.0001 ? avg / len : d1
            }

            // Perpendicular in XZ plane (rotate 90 degrees)
            let perp = SIMD2<Float>(-direction.y, direction.x)

            let y = point.y + yOffset

            // Left and right vertices
            let left = SIMD3<Float>(
                point.x + perp.x * halfWidth,
                y,
                point.z + perp.y * halfWidth
            )
            let right = SIMD3<Float>(
                point.x - perp.x * halfWidth,
                y,
                point.z - perp.y * halfWidth
            )

            positions.append(left)
            positions.append(right)

            // Normals point up
            normals.append(SIMD3<Float>(0, 1, 0))
            normals.append(SIMD3<Float>(0, 1, 0))

            // UVs: U maps across width (0 = left, 1 = right), V maps along length
            let v = totalLength > 0 ? cumulativeLength(points, to: i) / totalLength : 0
            uvs.append(SIMD2<Float>(0, v))
            uvs.append(SIMD2<Float>(1, v))
        }

        // Generate triangle indices: 2 triangles per segment
        for i in 0..<(points.count - 1) {
            let base = UInt32(i * 2)
            // Triangle 1: left[i], left[i+1], right[i]
            indices.append(contentsOf: [base, base + 2, base + 1])
            // Triangle 2: right[i], left[i+1], right[i+1]
            indices.append(contentsOf: [base + 1, base + 2, base + 3])
        }

        var descriptor = MeshDescriptor(name: "polyline")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)

        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            throw DioramaError.meshGenerationFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Private

    private static func cumulativeLengths(_ points: [SIMD3<Float>]) -> Float {
        var total: Float = 0
        for i in 1..<points.count {
            total += simd_distance(points[i - 1], points[i])
        }
        return total
    }

    private static func cumulativeLength(_ points: [SIMD3<Float>], to index: Int) -> Float {
        var total: Float = 0
        for i in 1...max(1, index) {
            guard i < points.count else { break }
            total += simd_distance(points[i - 1], points[i])
        }
        return index == 0 ? 0 : total
    }
}
