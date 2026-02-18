import Foundation
import RealityKit
import simd

/// Generates RealityKit `MeshResource` instances from elevation grids.
public enum TerrainMeshGenerator {
    /// Generates a terrain mesh from one or more elevation grids.
    ///
    /// The terrain is shifted so minimum elevation sits at Y=0 (flush with the pedestal rim).
    /// When a `clipRadius` is provided, vertices outside the circle are projected onto the boundary,
    /// and a vertical skirt wall is added around the perimeter.
    ///
    /// - Parameters:
    ///   - grids: Elevation grids, one per tile.
    ///   - tilePositions: The tile x/y positions corresponding to each grid (used for spatial arrangement).
    ///   - exaggeration: Elevation exaggeration multiplier. `0` produces a flat mesh.
    ///   - physicalDiameter: The physical diameter of the output mesh in meters.
    ///   - radiusMeters: The real-world geographic radius in meters that the diorama covers.
    ///   - clipRadius: If non-nil, clips the terrain to a circle of this radius and adds a skirt wall.
    ///   - resolution: Grid resolution to use. If smaller than the grid, it will be downsampled. Default `256`.
    /// - Returns: A `MeshResource` representing the terrain.
    @MainActor
    public static func generateMesh(
        from grids: [ElevationGrid],
        tilePositions: [(x: Int, y: Int)],
        exaggeration: Float,
        physicalDiameter: Float,
        radiusMeters: Double,
        clipRadius: Float? = nil,
        resolution: Int = 256
    ) throws -> MeshResource {
        guard let firstGrid = grids.first else {
            throw DioramaError.meshGenerationFailed(reason: "No elevation grids provided")
        }

        // Compute global min elevation across ALL grids for consistent baseline
        let globalMinElev = grids.map(\.minElevation).min() ?? 0

        // For single-tile, generate directly
        if grids.count == 1 {
            return try generateSingleTileMesh(
                grid: firstGrid,
                exaggeration: exaggeration,
                physicalDiameter: physicalDiameter,
                radiusMeters: radiusMeters,
                clipRadius: clipRadius,
                globalMinElev: globalMinElev,
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

        // Per-axis tile sizes so the mesh fills the full physicalDiameter in both dimensions,
        // even when the tile grid is not square (e.g. 2×3 tiles).
        let tileSizeX = physicalDiameter / Float(tilesWide)
        let tileSizeZ = physicalDiameter / Float(tilesTall)

        // Geographic scale: converts real-world meters to physical diorama meters
        let geographicScale = Float(physicalDiameter) / Float(radiusMeters * 2.0)

        var allPositions: [SIMD3<Float>] = []
        var allNormals: [SIMD3<Float>] = []
        var allUVs: [SIMD2<Float>] = []
        var allIndices: [UInt32] = []

        for (i, grid) in grids.enumerated() {
            let tx = tilePositions[i].x - minX
            let ty = tilePositions[i].y - minY
            let offsetX = Float(tx) * tileSizeX - physicalDiameter / 2.0 + tileSizeX / 2.0
            let offsetZ = Float(ty) * tileSizeZ - physicalDiameter / 2.0 + tileSizeZ / 2.0

            let baseIndex = UInt32(allPositions.count)
            let res = min(resolution, min(grid.width, grid.height))
            let (positions, normals, uvs, indices) = generateGridGeometry(
                grid: grid,
                resolution: res,
                sizeX: tileSizeX,
                sizeZ: tileSizeZ,
                geographicScale: geographicScale,
                exaggeration: exaggeration,
                offsetX: offsetX,
                offsetZ: offsetZ,
                uvOffsetX: Float(tx) / Float(tilesWide),
                uvOffsetY: Float(ty) / Float(tilesTall),
                uvScaleX: 1.0 / Float(tilesWide),
                uvScaleY: 1.0 / Float(tilesTall),
                clipRadius: clipRadius,
                globalMinElev: globalMinElev
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
        clipRadius: Float? = nil,
        globalMinElev: Float? = nil,
        resolution: Int = 256
    ) throws -> MeshResource {
        let res = min(resolution, min(grid.width, grid.height))
        let geographicScale = Float(physicalDiameter) / Float(radiusMeters * 2.0)
        let minElev = globalMinElev ?? grid.minElevation

        let (positions, normals, uvs, indices) = generateGridGeometry(
            grid: grid,
            resolution: res,
            sizeX: physicalDiameter,
            sizeZ: physicalDiameter,
            geographicScale: geographicScale,
            exaggeration: exaggeration,
            offsetX: 0,
            offsetZ: 0,
            uvOffsetX: 0,
            uvOffsetY: 0,
            uvScaleX: 1.0,
            uvScaleY: 1.0,
            clipRadius: clipRadius,
            globalMinElev: minElev
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
        sizeX: Float,
        sizeZ: Float,
        geographicScale: Float,
        exaggeration: Float,
        offsetX: Float,
        offsetZ: Float,
        uvOffsetX: Float,
        uvOffsetY: Float,
        uvScaleX: Float,
        uvScaleY: Float,
        clipRadius: Float? = nil,
        globalMinElev: Float? = nil
    ) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32]) {
        let step = max(1, grid.width / resolution)
        let cols = (grid.width - 1) / step + 1
        let rows = (grid.height - 1) / step + 1
        let halfSizeX = sizeX / 2.0
        let halfSizeZ = sizeZ / 2.0

        // The elevation scale converts real-world elevation meters into diorama-space meters.
        let elevationScale = geographicScale * exaggeration

        // Use the global minimum elevation as baseline so the lowest point sits at Y=0
        let baseElev = globalMinElev ?? grid.minElevation

        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var isBoundary: [Bool] = [] // Tracks which vertices are on the clipping boundary
        positions.reserveCapacity(cols * rows)
        uvs.reserveCapacity(cols * rows)
        isBoundary.reserveCapacity(cols * rows)

        for row in 0..<rows {
            for col in 0..<cols {
                let gridCol = min(col * step, grid.width - 1)
                let gridRow = min(row * step, grid.height - 1)

                var x = Float(col) / Float(cols - 1) * sizeX - halfSizeX + offsetX
                var z = Float(row) / Float(rows - 1) * sizeZ - halfSizeZ + offsetZ
                let rawElevation = grid.elevation(atColumn: gridCol, row: gridRow)
                var y = (rawElevation - baseElev) * elevationScale

                // Circular clipping: project vertices outside the circle onto the boundary
                var onBoundary = false
                if let radius = clipRadius {
                    let dist = sqrt(x * x + z * z)
                    if dist > radius {
                        let scale = radius / dist
                        x *= scale
                        z *= scale
                        y = 0 // Flatten clipped vertices to base
                        onBoundary = true
                    } else if dist > radius * 0.95 {
                        // Near the edge — mark as boundary for skirt generation
                        onBoundary = true
                    }
                } else {
                    // Rectangular: edges of the grid are boundaries
                    if row == 0 || row == rows - 1 || col == 0 || col == cols - 1 {
                        onBoundary = true
                    }
                }

                positions.append(SIMD3<Float>(x, y, z))
                isBoundary.append(onBoundary)

                let u = uvOffsetX + Float(col) / Float(cols - 1) * uvScaleX
                let v = uvOffsetY + Float(row) / Float(rows - 1) * uvScaleY
                uvs.append(SIMD2<Float>(u, v))
            }
        }

        // Generate triangle indices for surface
        var indices: [UInt32] = []
        indices.reserveCapacity((cols - 1) * (rows - 1) * 6)

        for row in 0..<(rows - 1) {
            for col in 0..<(cols - 1) {
                let topLeft = UInt32(row * cols + col)
                let topRight = topLeft + 1
                let bottomLeft = UInt32((row + 1) * cols + col)
                let bottomRight = bottomLeft + 1

                // For circular clipping, skip triangles where all 3 vertices are clipped to the boundary
                if let radius = clipRadius {
                    let p0 = positions[Int(topLeft)]
                    let p1 = positions[Int(topRight)]
                    let p2 = positions[Int(bottomLeft)]
                    let p3 = positions[Int(bottomRight)]

                    let allOutside0 = sqrt(p0.x * p0.x + p0.z * p0.z) >= radius &&
                                      sqrt(p2.x * p2.x + p2.z * p2.z) >= radius &&
                                      sqrt(p1.x * p1.x + p1.z * p1.z) >= radius
                    let allOutside1 = sqrt(p1.x * p1.x + p1.z * p1.z) >= radius &&
                                      sqrt(p2.x * p2.x + p2.z * p2.z) >= radius &&
                                      sqrt(p3.x * p3.x + p3.z * p3.z) >= radius

                    if !allOutside0 {
                        indices.append(contentsOf: [topLeft, bottomLeft, topRight])
                    }
                    if !allOutside1 {
                        indices.append(contentsOf: [topRight, bottomLeft, bottomRight])
                    }
                } else {
                    indices.append(contentsOf: [topLeft, bottomLeft, topRight])
                    indices.append(contentsOf: [topRight, bottomLeft, bottomRight])
                }
            }
        }

        // --- Skirt wall generation ---
        // Collect ordered boundary vertices and add a vertical wall from each down to Y=0
        var boundaryVertexIndices: [Int] = []
        for i in 0..<positions.count where isBoundary[i] {
            // Only include vertices that are actually part of visible triangles
            if positions[i].y > 0 || clipRadius == nil {
                boundaryVertexIndices.append(i)
            }
        }

        // Sort boundary vertices by angle from center for continuous wall
        if !boundaryVertexIndices.isEmpty {
            boundaryVertexIndices.sort { a, b in
                let pa = positions[a]
                let pb = positions[b]
                return atan2(pa.z, pa.x) < atan2(pb.z, pb.x)
            }

            let skirtBaseIndex = UInt32(positions.count)
            var skirtPositions: [SIMD3<Float>] = []
            var skirtUVs: [SIMD2<Float>] = []
            var skirtNormals: [SIMD3<Float>] = []
            var skirtIndices: [UInt32] = []

            for (si, vi) in boundaryVertexIndices.enumerated() {
                let topPos = positions[vi]
                let bottomPos = SIMD3<Float>(topPos.x, 0, topPos.z)

                // Outward-facing normal
                let outward = simd_normalize(SIMD3<Float>(topPos.x, 0, topPos.z))
                let normal = simd_length(outward) > 0 ? outward : SIMD3<Float>(0, 0, 1)

                // Top vertex (surface edge)
                skirtPositions.append(topPos)
                skirtNormals.append(normal)
                skirtUVs.append(uvs[vi])

                // Bottom vertex (at Y=0)
                skirtPositions.append(bottomPos)
                skirtNormals.append(normal)
                skirtUVs.append(SIMD2<Float>(uvs[vi].x, uvs[vi].y))

                // Connect to next boundary vertex
                if si < boundaryVertexIndices.count - 1 {
                    let base = skirtBaseIndex + UInt32(si * 2)
                    let next = base + 2

                    // Two triangles for the wall quad
                    skirtIndices.append(contentsOf: [base, base + 1, next])
                    skirtIndices.append(contentsOf: [next, base + 1, next + 1])
                }
            }

            // Close the skirt loop (last vertex connects to first)
            if boundaryVertexIndices.count > 2 {
                let lastBase = skirtBaseIndex + UInt32((boundaryVertexIndices.count - 1) * 2)
                let firstBase = skirtBaseIndex

                skirtIndices.append(contentsOf: [lastBase, lastBase + 1, firstBase])
                skirtIndices.append(contentsOf: [firstBase, lastBase + 1, firstBase + 1])
            }

            positions.append(contentsOf: skirtPositions)
            uvs.append(contentsOf: skirtUVs)
            indices.append(contentsOf: skirtIndices)

            // We'll compute normals for skirt vertices in the global normal pass below
            // For now, extend the isBoundary array to cover new vertices
            isBoundary.append(contentsOf: [Bool](repeating: false, count: skirtPositions.count))

            // Pre-assign skirt normals, they'll be overwritten by the normal computation
            // but we set them as fallback
            _ = skirtNormals // normals computed below from face normals
        }

        // Compute normals for ALL vertices (surface + skirt)
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for i in stride(from: 0, to: indices.count, by: 3) {
            let i0 = Int(indices[i])
            let i1 = Int(indices[i + 1])
            let i2 = Int(indices[i + 2])

            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }

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
