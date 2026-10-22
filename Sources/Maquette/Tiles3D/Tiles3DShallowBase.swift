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
    struct Geometry {
        var mesh = Tiles3DCutWall.Geometry()
        var parts: [LowLevelMesh.Part] = []
    }

    static func build(edges: [Tiles3DCutEdge], lowestY: Float, prism: BoundaryPrism,
        earthDepth: Float, trayDepth: Float, includesWalls: Bool
    ) throws -> Geometry? {
        // Bound staging too, before allocating four vertices per source cut and material band.
        guard edges.count <= 12_500 else { throw OverlayGeometryError.budgetExceeded }
        var result = Geometry()
        func append(_ band: Tiles3DCutWall.Geometry?, material: Int) {
            guard let band else { return }
            let offset = UInt32(result.mesh.vertices.count)
            result.parts.append(.init(indexOffset: result.mesh.indices.count * MemoryLayout<UInt32>.stride,
                indexCount: band.indices.count, materialIndex: material, bounds: band.bounds))
            result.mesh.vertices.append(contentsOf: band.vertices)
            result.mesh.indices.append(contentsOf: band.indices.map { $0 + offset })
            result.mesh.lower = simd_min(result.mesh.lower, band.lower)
            result.mesh.upper = simd_max(result.mesh.upper, band.upper)
        }
        if includesWalls {
            append(Tiles3DCutWall.buildGeometry(edges: edges, floorY: lowestY - earthDepth,
                prism: prism, maximumThickness: earthDepth), material: 0)
        }
        if trayDepth > 0 {
            let lowerEdges = edges.map { edge in
                var edge = edge
                edge.a.y -= earthDepth; edge.b.y -= earthDepth
                return edge
            }
            append(Tiles3DCutWall.buildGeometry(edges: lowerEdges,
                floorY: lowestY - earthDepth - trayDepth, prism: prism,
                maximumThickness: trayDepth), material: 1)
        }
        return result.mesh.isEmpty ? nil : try Tiles3DWallCoverage.resolve(result, prism: prism, earthDepth: earthDepth, trayDepth: trayDepth)
    }
}
