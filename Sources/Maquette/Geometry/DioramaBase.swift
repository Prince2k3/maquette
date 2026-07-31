import Foundation
import RealityKit
import SwiftUI
import simd

/// Generates the optional display base a terrain chunk rests on.
///
/// The chunk itself is a closed solid, so a base is decoration rather than structure — it exists to
/// present the chunk, not to hide an open underside. It follows the chunk's own outline so the
/// silhouette stays coherent for any shape.
enum DioramaBase {
    /// Generates the base entity for a chunk.
    ///
    /// - Parameters:
    ///   - style: The base style to realize.
    ///   - boundary: The chunk's outline.
    ///   - chunkBottomY: Diorama-space Y of the chunk's underside, normally `-baseDepth`.
    /// - Returns: An entity containing the base geometry, or `nil` for `.none`.
    @MainActor
    public static func generate(
        style: ChunkBaseStyle,
        boundary: DioramaBoundary,
        chunkBottomY: Float
    ) throws -> Entity? {
        switch style {
        case .none:
            return nil

        case .plinth(let color, let height, let inset):
            guard height > 0 else { return nil }
            let outline = inset != 0 ? offset(boundary.vertices, by: -inset) : boundary.vertices
            guard outline.count >= 3 else { return nil }

            let mesh = try prismMesh(
                outline: outline,
                topY: chunkBottomY,
                bottomY: chunkBottomY - height
            )
            let entity = ModelEntity(
                mesh: mesh,
                materials: [DioramaMaterials.litMaterial(color: color, roughness: 0.6)]
            )
            entity.name = "DioramaPlinth"

            let container = Entity()
            container.name = "DioramaBase"
            container.addChild(entity)
            return container
        }
    }

    // MARK: - Geometry

    /// Builds a closed prism from a horizontal outline.
    @MainActor
    static func prismMesh(
        outline: [SIMD2<Float>],
        topY: Float,
        bottomY: Float
    ) throws -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        var lo = outline[0]
        var hi = outline[0]
        for point in outline.dropFirst() {
            lo = simd_min(lo, point)
            hi = simd_max(hi, point)
        }
        let size = simd_max(hi - lo, SIMD2(repeating: .ulpOfOne))

        func planarUV(_ point: SIMD2<Float>) -> SIMD2<Float> {
            (point - lo) / size
        }

        // Top face — the outline's winding already yields +Y normals.
        let topStart = UInt32(positions.count)
        for point in outline {
            positions.append(SIMD3(point.x, topY, point.y))
            normals.append(SIMD3(0, 1, 0))
            uvs.append(planarUV(point))
        }
        for i in 1..<(outline.count - 1) {
            indices.append(contentsOf: [topStart, topStart + UInt32(i), topStart + UInt32(i + 1)])
        }

        // Bottom face — reversed winding so it looks down.
        let bottomStart = UInt32(positions.count)
        for point in outline {
            positions.append(SIMD3(point.x, bottomY, point.y))
            normals.append(SIMD3(0, -1, 0))
            uvs.append(planarUV(point))
        }
        for i in 1..<(outline.count - 1) {
            indices.append(contentsOf: [bottomStart, bottomStart + UInt32(i + 1), bottomStart + UInt32(i)])
        }

        // Side wall.
        let perimeter = outlinePerimeter(outline)
        var travelled: Float = 0
        for i in 0..<outline.count {
            let a = outline[i]
            let b = outline[(i + 1) % outline.count]
            let normal = DioramaBoundary.outwardNormal(forEdgeFrom: a, to: b)
            let segmentLength = simd_distance(a, b)
            let uA = perimeter > 0 ? travelled / perimeter : 0
            let uB = perimeter > 0 ? (travelled + segmentLength) / perimeter : 0
            travelled += segmentLength

            let base = UInt32(positions.count)
            positions.append(SIMD3(a.x, topY, a.y))
            normals.append(normal)
            uvs.append(SIMD2(uA, 1))

            positions.append(SIMD3(a.x, bottomY, a.y))
            normals.append(normal)
            uvs.append(SIMD2(uA, 0))

            positions.append(SIMD3(b.x, topY, b.y))
            normals.append(normal)
            uvs.append(SIMD2(uB, 1))

            positions.append(SIMD3(b.x, bottomY, b.y))
            normals.append(normal)
            uvs.append(SIMD2(uB, 0))

            indices.append(contentsOf: [base, base + 1, base + 3])
            indices.append(contentsOf: [base, base + 3, base + 2])
        }

        var descriptor = MeshDescriptor(name: "dioramaBase")
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

    /// Offsets a closed outline along its vertex bisectors.
    ///
    /// Positive distances move the outline outward. Exact for convex outlines; miter lengths are
    /// clamped so sharp corners cannot shoot out into spikes.
    static func offset(_ outline: [SIMD2<Float>], by distance: Float) -> [SIMD2<Float>] {
        guard outline.count >= 3, distance != 0 else { return outline }

        var result: [SIMD2<Float>] = []
        result.reserveCapacity(outline.count)

        for i in 0..<outline.count {
            let previous = outline[(i + outline.count - 1) % outline.count]
            let current = outline[i]
            let next = outline[(i + 1) % outline.count]

            let incoming = safeNormalize(current - previous)
            let outgoing = safeNormalize(next - current)

            // Outward normal of an edge with direction d is (-d.y, d.x).
            let n1 = SIMD2(-incoming.y, incoming.x)
            let n2 = SIMD2(-outgoing.y, outgoing.x)

            let bisector = safeNormalize(n1 + n2)
            let projection = simd_dot(bisector, n1)
            // Clamp so near-reflex corners do not produce runaway miters.
            let miter = abs(projection) > 0.25 ? distance / projection : distance * 4
            result.append(current + bisector * miter)
        }

        return result
    }

    private static func outlinePerimeter(_ outline: [SIMD2<Float>]) -> Float {
        var total: Float = 0
        for i in 0..<outline.count {
            total += simd_distance(outline[i], outline[(i + 1) % outline.count])
        }
        return total
    }

    private static func safeNormalize(_ vector: SIMD2<Float>) -> SIMD2<Float> {
        let length = simd_length(vector)
        return length > .ulpOfOne ? vector / length : SIMD2(0, 1)
    }
}
