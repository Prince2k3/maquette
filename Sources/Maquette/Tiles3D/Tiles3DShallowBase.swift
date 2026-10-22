import RealityKit
import SwiftUI
import simd

/// The tray and earth share one physical thickness budget. Leave at least half for earth even
/// when an application requests an oversized tray. All quantities here are diorama metres.
struct Tiles3DShallowBaseLayout {
    let maximumThickness: Float
    let earthDepth: Float
    let trayThickness: Float

    init(boundary: DioramaBoundary, base: Tiles3DBase) {
        maximumThickness = ChunkThicknessLimit.maximum(for: boundary)
        if case .tray(_, let requested, _) = base {
            trayThickness = requested.isFinite ? min(max(0, requested), maximumThickness / 2) : 0
        } else {
            trayThickness = 0
        }
        earthDepth = maximumThickness - trayThickness
    }
}

/// A surface-following underside sharing its source tile's mesh. Front-face culling shows the
/// reverse of that mesh without duplicating its CPU geometry or allocating another GPU buffer.
/// Its parent owns visibility and lifetime, so an obsolete LOD cannot leave an underside behind.
@MainActor
final class Tiles3DShallowUnderside {
    static let name = "Tiles3DShallowUnderside"
    let depth: Float
    private let material: UnlitMaterial

    init(depth: Float, color: Color) {
        self.depth = depth
        var material = DioramaMaterials.unlitMaterial(color: color)
        material.faceCulling = .front
        self.material = material
    }

    func install(on tile: ModelEntity) {
        guard let source = tile.model else { remove(from: tile); return }
        let underside = tile.children.first { $0.name == Self.name } as? ModelEntity ?? ModelEntity()
        let count = max(1, source.materials.count)
        if underside.model?.mesh !== source.mesh || underside.model?.materials.count != count {
            underside.model = ModelComponent(mesh: source.mesh, materials: Array(repeating: material, count: count))
        }
        // Source placement may rotate/scale its local up axis. Convert a vertical displacement
        // in the clipping frame back to that source frame; its X/Z footprint must not move.
        let offset = simd_inverse(tile.transform.matrix) * SIMD4<Float>(0, -depth, 0, 0)
        let position = SIMD3(offset.x, offset.y, offset.z)
        if underside.position != position { underside.position = position }
        if underside.parent == nil {
            underside.name = Self.name
            tile.addChild(underside)
        }
    }

    func remove(from tile: ModelEntity) {
        tile.children.first { $0.name == Self.name }?.removeFromParent()
    }
}


/// Both material bands live in one retained buffer, so a failed growth cannot publish half a rim.
/// The lower tray band follows exactly the same cut segments as the earth and shared underside.
enum Tiles3DShallowClosure {
    struct Geometry: Sendable {
        var mesh = Tiles3DCutWall.Geometry()
        var parts: [LowLevelMesh.Part] = []
    }

    /// Coverage on different boundary edges is independent. Keep all cuts for one edge together
    /// so overlapping earth/tray patches still resolve exactly once. Four bounded workers share
    /// the original output/work quotas; an uneven arrangement can fall back to one serial attempt.
    static func buildParallel(edges: [Tiles3DCutEdge], lowestY: Float, prism: BoundaryPrism,
        earthDepth: Float, trayDepth: Float, includesWalls: Bool
    ) async throws -> Geometry? {
        guard edges.count <= 12_500 else { throw OverlayGeometryError.budgetExceeded }
        guard edges.count >= 1_024 else {
            return try build(edges: edges, lowestY: lowestY, prism: prism,
                earthDepth: earthDepth, trayDepth: trayDepth, includesWalls: includesWalls)
        }
        var buckets = Array(repeating: [Tiles3DCutEdge](), count: 4)
        for edge in edges where prism.boundary.vertices.indices.contains(edge.boundaryEdge) {
            buckets[edge.boundaryEdge % 4].append(edge)
        }
        let jobs = buckets.filter { !$0.isEmpty }
        guard jobs.count > 1 else {
            return try build(edges: edges, lowestY: lowestY, prism: prism,
                earthDepth: earthDepth, trayDepth: trayDepth, includesWalls: includesWalls)
        }
        do {
            let sections = try await withThrowingTaskGroup(of: (Int, Geometry).self) { group in
                for (index, cuts) in jobs.enumerated() {
                    group.addTask {
                        let limits = OverlayGeometryLimits(maxTriangles: max(1, 50_000 * cuts.count / edges.count),
                            maxOperations: max(1, 20_000_000 * cuts.count / edges.count))
                        return (index, try Tiles3DWallCoverage.resolve(edges: cuts, lowestY: lowestY, prism: prism,
                            earthDepth: earthDepth, trayDepth: trayDepth, includesWalls: includesWalls, limits: limits))
                    }
                }
                var result = Array<Geometry?>(repeating: nil, count: jobs.count)
                for try await (index, section) in group { result[index] = section }
                return result.compactMap { $0 }
            }
            try Task.checkCancellation()
            var result = Geometry(), bases: [UInt32] = []
            let vertexCount = sections.reduce(0) { $0 + $1.mesh.vertices.count }
            let indexCount = sections.reduce(0) { $0 + $1.mesh.indices.count }
            guard vertexCount < Int(UInt32.max), indexCount / 3 <= 50_000 else {
                throw OverlayGeometryError.budgetExceeded
            }
            result.mesh.vertices.reserveCapacity(vertexCount); result.mesh.indices.reserveCapacity(indexCount)
            for section in sections {
                bases.append(UInt32(result.mesh.vertices.count))
                result.mesh.vertices.append(contentsOf: section.mesh.vertices)
            }
            // Preserve two material parts rather than multiplying draw calls by worker count.
            for material in 0..<2 {
                let start = result.mesh.indices.count
                var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                for (index, section) in sections.enumerated() {
                    for part in section.parts where part.materialIndex == material {
                        let first = part.indexOffset / MemoryLayout<UInt32>.stride
                        result.mesh.indices.append(contentsOf: section.mesh.indices[first..<(first + part.indexCount)].map { $0 + bases[index] })
                        lower = simd_min(lower, part.bounds.min); upper = simd_max(upper, part.bounds.max)
                    }
                }
                guard result.mesh.indices.count > start else { continue }
                result.parts.append(.init(indexOffset: start * MemoryLayout<UInt32>.stride,
                    indexCount: result.mesh.indices.count - start, materialIndex: material,
                    bounds: BoundingBox(min: lower, max: upper)))
                result.mesh.lower = simd_min(result.mesh.lower, lower)
                result.mesh.upper = simd_max(result.mesh.upper, upper)
            }
            return result.mesh.isEmpty ? nil : result
        } catch OverlayGeometryError.budgetExceeded {
            // Proportional quotas can reject an otherwise valid unbalanced edge. Retry once with
            // the original aggregate quota; cancellation and invalid geometry are never retried.
            try Task.checkCancellation()
            return try build(edges: edges, lowestY: lowestY, prism: prism,
                earthDepth: earthDepth, trayDepth: trayDepth, includesWalls: includesWalls)
        }
    }

    static func build(edges: [Tiles3DCutEdge], lowestY: Float, prism: BoundaryPrism,
        earthDepth: Float, trayDepth: Float, includesWalls: Bool
    ) throws -> Geometry? {
        // Bound staging too, before allocating four vertices per source cut and material band.
        guard edges.count <= 12_500 else { throw OverlayGeometryError.budgetExceeded }
        let result = try Tiles3DWallCoverage.resolve(edges: edges, lowestY: lowestY, prism: prism,
            earthDepth: earthDepth, trayDepth: trayDepth, includesWalls: includesWalls)
        return result.mesh.isEmpty ? nil : result
    }
}
