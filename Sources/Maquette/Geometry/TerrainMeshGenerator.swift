import Foundation
import RealityKit
import simd

/// Generates RealityKit `MeshResource` instances from elevation grids.
public enum TerrainMeshGenerator {
    /// Generates a terrain mesh from one or more elevation grids.
    ///
    /// - Parameters:
    ///   - grids: Elevation grids, one per tile.
    ///   - tilePositions: The tile x/y positions corresponding to each grid (used for spatial arrangement).
    ///   - exaggeration: Elevation exaggeration multiplier. `0` produces a flat mesh.
    ///   - physicalDiameter: The physical diameter of the output mesh in meters.
    ///   - radiusMeters: The real-world geographic radius in meters that the diorama covers.
    ///   - resolution: Grid resolution to use. If smaller than the grid, it will be downsampled. Default `128`.
    /// - Returns: A `MeshResource` representing the terrain.
    @MainActor
    public static func generateMesh(
        from grids: [ElevationGrid],
        tilePositions: [(x: Int, y: Int)],
        exaggeration: Float,
        physicalDiameter: Float,
        radiusMeters: Double,
        resolution: Int = 256
    ) throws -> MeshResource {
        guard let firstGrid = grids.first else {
            throw DioramaError.meshGenerationFailed(reason: "No elevation grids provided")
        }

        // For single-tile, generate directly
        if grids.count == 1 {
            return try generateSingleTileMesh(
                grid: firstGrid,
                exaggeration: exaggeration,
                physicalDiameter: physicalDiameter,
                radiusMeters: radiusMeters,
                resolution: resolution
            )
        }

        // Multi-tile: find bounds and generate each tile mesh offset appropriately
        let minX = tilePositions.map(\.x).min()!
        let minY = tilePositions.map(\.y).min()!
        let maxX = tilePositions.map(\.x).max()!
        let maxY = tilePositions.map(\.y).max()!
        let tilesWide = maxX - minX + 1
        let tilesTall = maxY - minY + 1
        let tileSize = physicalDiameter / Float(max(tilesWide, tilesTall))

        // Geographic scale: converts real-world meters to physical diorama meters
        let geographicScale = Float(physicalDiameter) / Float(radiusMeters * 2.0)

        var allPositions: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allUVs: [SIMD2<Float>] = []
        var allIndices: [UInt32] = []

        for (i, grid) in grids.enumerated() {
            let tx = tilePositions[i].x - minX
            let ty = tilePositions[i].y - minY
            let offsetX = Float(tx) * tileSize - physicalDiameter / 2.0 + tileSize / 2.0
            let offsetZ = Float(ty) * tileSize - physicalDiameter / 2.0 + tileSize / 2.0

            let baseIndex = UInt32(allPositions.count)
            let res = min(resolution, min(grid.width, grid.height))
            let (positions, normals, uvs, indices) = generateGridGeometry(
                grid: grid,
                resolution: res,
                size: tileSize,
                geographicScale: geographicScale,
                exaggeration: exaggeration,
                offsetX: offsetX,
                offsetZ: offsetZ,
                uvOffsetX: Float(tx) / Float(tilesWide),
                uvOffsetY: Float(ty) / Float(tilesTall),
                uvScale: 1.0 / Float(max(tilesWide, tilesTall))
            )

            allPositions.append(contentsOf: positions)
            allNormals.append(contentsOf: normals)
            allUVs.append(contentsOf: uvs)
            allIndices.append(contentsOf: indices.map { $0 + baseIndex })
        }

        return try buildMeshResource(
            positions: allPositions,
            normals: allNormals,
            uvs: allUVs,
            indices: allIndices
        )
    }

    /// Generates a mesh for a single elevation grid tile.
    @MainActor
    public static func generateSingleTileMesh(
        grid: ElevationGrid,
        exaggeration: Float,
        physicalDiameter: Float,
        radiusMeters: Double,
        resolution: Int = 256
    ) throws -> MeshResource {
        let res = min(resolution, min(grid.width, grid.height))
        let geographicScale = Float(physicalDiameter) / Float(radiusMeters * 2.0)

        let (positions, normals, uvs, indices) = generateGridGeometry(
            grid: grid,
            resolution: res,
            size: physicalDiameter,
            geographicScale: geographicScale,
            exaggeration: exaggeration,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScale: 1.0
        )

        return try buildMeshResource(
            positions: positions,
            normals: normals,
            uvs: uvs,
            indices: indices
        )
    }

    // MARK: - Internal Geometry Generation

    static func generateGridGeometry(
        grid: ElevationGrid,
        resolution: Int,
        size: Float,
        geographicScale: Float,
        exaggeration: Float,
        offsetX: Float,
        offsetZ: Float,
        uvOffsetX: Float,
        uvOffsetY: Float,
        uvScale: Float
    ) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]) {
        let step = max(1, grid.width / resolution)
        let cols = (grid.width - 1) / step + 1
        let rows = (grid.height - 1) / step + 1
        let halfSize = size / 2.0

        // The elevation scale converts real-world elevation meters into diorama-space meters.
        // geographicScale = physicalDiameter / geographicDiameter gives the horizontal ratio.
        // Multiply by exaggeration to make terrain features more visible.
        let elevationScale = geographicScale * exaggeration

        // Center the elevation around the grid's midpoint so the terrain isn't
        // floating high above the origin. Compute the min elevation to use as base.
        let minElev = grid.minElevation
        let maxElev = grid.maxElevation
        let midElev = (minElev + maxElev) / 2.0

        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(cols * rows)
        uvs.reserveCapacity(cols * rows)

        for row in 0..<rows {
            for col in 0..<cols {
                let gridCol = min(col * step, grid.width - 1)
                let gridRow = min(row * step, grid.height - 1)

                let x = Float(col) / Float(cols - 1) * size - halfSize + offsetX
                let z = Float(row) / Float(rows - 1) * size - halfSize + offsetZ
                let rawElevation = grid.elevation(atColumn: gridCol, row: gridRow)
                let y = (rawElevation - midElev) * elevationScale

                positions.append(SIMD3<Float>(x, y, z))

                let u = uvOffsetX + Float(col) / Float(cols - 1) * uvScale
                let v = uvOffsetY + Float(row) / Float(rows - 1) * uvScale
                uvs.append(SIMD2<Float>(u, v))
            }
        }

        // Generate triangle indices
        var indices: [UInt32] = []
        indices.reserveCapacity((cols - 1) * (rows - 1) * 6)

        for row in 0..<(rows - 1) {
            for col in 0..<(cols - 1) {
                let topLeft = UInt32(row * cols + col)
                let topRight = topLeft + 1
                let bottomLeft = UInt32((row + 1) * cols + col)
                let bottomRight = bottomLeft + 1

                indices.append(contentsOf: [topLeft, bottomLeft, topRight])
                indices.append(contentsOf: [topRight, bottomLeft, bottomRight])
            }
        }

        // Compute normals — initialize to zero to avoid biasing
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for i in stride(from: 0, to: indices.count, by: 3) {
            let i0 = Int(indices[i])
            let i1 = Int(indices[i + 1])
            let i2 = Int(indices[i + 2])

            let v0 = positions[i0]
            let v1 = positions[i1]
            let v2 = positions[i2]

            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let faceNormal = simd_cross(edge1, edge2)
            let len = simd_length(faceNormal)
            guard len > 0 else { continue }
            let normal = faceNormal / len

            normals[i0] += normal
            normals[i1] += normal
            normals[i2] += normal
        }

        for i in 0..<normals.count {
            let len = simd_length(normals[i])
            if len > 0 {
                normals[i] /= len
            } else {
                normals[i] = SIMD3<Float>(0, 1, 0) // fallback up
            }
        }

        return (positions, normals, uvs, indices)
    }

    @MainActor
    private static func buildMeshResource(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        uvs: [SIMD2<Float>],
        indices: [UInt32]
    ) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: "terrain")
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
}
