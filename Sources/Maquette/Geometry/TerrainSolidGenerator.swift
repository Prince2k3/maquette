import Foundation
import RealityKit
import simd

/// The mesh parts that make up a terrain chunk.
///
/// The parts are separate meshes rather than one combined mesh so each can carry its own material:
/// satellite imagery on top, geological strata on the walls, a flat color underneath.
public struct TerrainSolidParts {
    /// The terrain surface, clipped to the boundary.
    public let top: MeshResource
    /// The cut walls running from the terrain surface down to the base depth, or `nil` if
    /// walls were not requested.
    public let walls: MeshResource?
    /// The closing face at the base depth, or `nil` if a bottom was not requested.
    public let bottom: MeshResource?
    /// Depth of the chunk below diorama Y = 0, in diorama meters.
    public let baseDepth: Float
    /// Highest point of the terrain surface in diorama-space Y.
    public let maxSurfaceY: Float

    /// Retained CPU-side geometry, so the surface can be re-sampled at a new pan offset without
    /// rebuilding topology. See `TerrainSolidGenerator.resample(_:heightField:panOffset:in:)`.
    let geometry: TerrainSolidGenerator.Geometry
    /// Parameters frozen at generation time so re-sampling stays consistent with the first build.
    let resampling: ResamplingParameters
}

/// Values that must stay fixed across pan updates for the chunk to remain visually stable.
struct ResamplingParameters {
    /// Chunk depth below Y = 0.
    let baseDepth: Float
    /// Vertical span the wall texture is normalized against.
    ///
    /// Frozen at generation. If it tracked the terrain currently under the boundary, the strata
    /// bands would slide up and down as the terrain panned beneath them.
    let wallHeight: Float
    /// Cell size, used as the step for the surface normal's central differences.
    let sampleStep: SIMD2<Float>
}

/// Generates a terrain chunk: a closed solid whose top is real terrain, whose sides are cut walls
/// showing the earth beneath, and whose bottom closes the volume.
///
/// The generator clips a regular sampling grid against a `DioramaBoundary`. Cells fully inside the
/// boundary become quads; cells the boundary crosses are clipped to polygons that follow the
/// outline exactly. Every clipped edge that lands on the boundary is extruded downward into a wall
/// quad, so the walls meet the surface with no gaps regardless of the chunk's silhouette.
public enum TerrainSolidGenerator {
    /// Generates the mesh parts for a terrain chunk.
    ///
    /// - Parameters:
    ///   - heightField: The terrain surface to sample.
    ///   - boundary: The outline to cut the chunk to.
    ///   - baseDepth: How far the chunk extends below diorama Y = 0, in diorama meters.
    ///   - includesWalls: Whether to generate the cut walls.
    ///   - includesBottom: Whether to close the chunk with a bottom face.
    ///   - resolution: Sampling cells along the chunk's longest horizontal axis.
    ///   - panOffset: Shifts which part of the height field appears inside the boundary. The
    ///     chunk's outline stays fixed; the terrain slides beneath it.
    /// - Returns: The generated mesh parts.
    @MainActor
    public static func generate(
        heightField: TerrainHeightField,
        boundary: DioramaBoundary,
        baseDepth: Float,
        includesWalls: Bool = true,
        includesBottom: Bool = true,
        resolution: Int = 256,
        panOffset: SIMD2<Float> = .zero
    ) throws -> TerrainSolidParts {
        let geometry = buildGeometry(
            heightField: heightField,
            boundary: boundary,
            baseDepth: baseDepth,
            includesWalls: includesWalls,
            includesBottom: includesBottom,
            resolution: resolution,
            panOffset: panOffset
        )

        guard !geometry.top.indices.isEmpty else {
            throw DioramaError.meshGenerationFailed(
                reason: "Terrain boundary enclosed no sampled area — check the diorama shape and radius"
            )
        }

        return TerrainSolidParts(
            top: try buildMesh(from: geometry.top, name: "terrainTop"),
            walls: geometry.walls.indices.isEmpty ? nil : try buildMesh(from: geometry.walls, name: "terrainWalls"),
            bottom: geometry.bottom.indices.isEmpty ? nil : try buildMesh(from: geometry.bottom, name: "terrainBottom"),
            baseDepth: baseDepth,
            maxSurfaceY: heightField.maxSurfaceY,
            geometry: geometry,
            resampling: geometry.resampling
        )
    }

    // MARK: - Panning

    /// Re-samples a chunk's surface at a new pan offset, updating the retained buffers in place.
    ///
    /// The chunk's outline is fixed in diorama space, so panning changes neither the topology nor
    /// the horizontal vertex positions — only heights, normals, and texture coordinates. That is
    /// what makes panning affordable: the expensive part of generation, clipping the sampling grid
    /// against the boundary, is done once and reused for every offset.
    ///
    /// - Parameters:
    ///   - geometry: Retained geometry to update.
    ///   - heightField: The terrain surface to sample.
    ///   - panOffset: The new offset, in diorama meters.
    static func resample(
        _ geometry: inout Geometry,
        heightField: TerrainHeightField,
        panOffset: SIMD2<Float>
    ) {
        let parameters = geometry.resampling

        // Surface: height, shading, and imagery all follow the terrain.
        for index in geometry.top.positions.indices {
            let position = geometry.top.positions[index]
            let sample = SIMD2(position.x, position.z) + panOffset
            geometry.top.positions[index].y = heightField.surfaceY(atX: sample.x, z: sample.y)
            geometry.top.normals[index] = surfaceNormal(
                heightField: heightField,
                at: sample,
                sampleStep: parameters.sampleStep
            )
            geometry.top.uvs[index] = textureCoordinate(for: sample, heightField: heightField)
        }

        // Walls: `appendWallQuad` emits its four vertices as top, bottom, top, bottom, so the
        // even-indexed ones ride the surface and the odd-indexed ones stay pinned to the base.
        for index in stride(from: 0, to: geometry.walls.positions.count, by: 2) {
            let position = geometry.walls.positions[index]
            let sample = SIMD2(position.x, position.z) + panOffset
            let y = heightField.surfaceY(atX: sample.x, z: sample.y)
            geometry.walls.positions[index].y = y
            geometry.walls.uvs[index].y = parameters.wallHeight > 0
                ? ((y + parameters.baseDepth) / parameters.wallHeight).clampedToUnitRange
                : 0
        }

        // The bottom face is flat and untextured, so panning leaves it untouched.
    }

    // MARK: - Geometry Accumulation

    /// A mesh under construction.
    struct Buffers {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        mutating func addVertex(position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>) -> UInt32 {
            positions.append(position)
            normals.append(normal)
            uvs.append(uv)
            return UInt32(positions.count - 1)
        }

        mutating func addTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
            indices.append(contentsOf: [a, b, c])
        }
    }

    struct Geometry {
        var top = Buffers()
        var walls = Buffers()
        var bottom = Buffers()
        var resampling = ResamplingParameters(baseDepth: 0, wallHeight: 0, sampleStep: .one)
    }

    /// Builds all chunk geometry. Exposed for testing without a RealityKit device context.
    static func buildGeometry(
        heightField: TerrainHeightField,
        boundary: DioramaBoundary,
        baseDepth: Float,
        includesWalls: Bool,
        includesBottom: Bool,
        resolution: Int,
        panOffset: SIMD2<Float> = .zero
    ) -> Geometry {
        var geometry = Geometry()

        let extent = boundary.extent
        let origin = boundary.minCorner
        let longestAxis = max(extent.x, extent.y)
        guard longestAxis > 0, resolution > 0 else { return geometry }

        let cellsX = max(1, Int((Float(resolution) * extent.x / longestAxis).rounded()))
        let cellsZ = max(1, Int((Float(resolution) * extent.y / longestAxis).rounded()))
        let cellSize = SIMD2(extent.x / Float(cellsX), extent.y / Float(cellsZ))

        // Boundary edges bucketed by cell row, so each cell only tests edges that could reach it.
        let edgesByRow = bucketEdgesByRow(
            boundary: boundary,
            origin: origin,
            cellSizeZ: cellSize.y,
            rowCount: cellsZ
        )

        // Vertices shared between neighbouring interior cells. Allocated on first use so cells
        // outside the boundary cost nothing.
        var topGridSlots = [Int32](repeating: -1, count: (cellsX + 1) * (cellsZ + 1))
        var bottomGridSlots = [Int32](repeating: -1, count: (cellsX + 1) * (cellsZ + 1))

        // Walls exist only along the boundary, where the terrain usually sits well below the
        // region's highest point. Normalizing the wall's vertical texture coordinate against the
        // global maximum would squeeze every wall into the bottom of the strata texture and show a
        // single band, so measure the range the walls actually span. Edge midpoints are sampled
        // alongside vertices to catch ridges that crest between two boundary vertices.
        var maxBoundarySurfaceY: Float = 0
        for index in 0..<boundary.edgeCount {
            let (a, b) = boundary.edge(index)
            let midpoint = (a + b) / 2
            for point in [a, midpoint] {
                let sample = point + panOffset
                maxBoundarySurfaceY = max(
                    maxBoundarySurfaceY,
                    heightField.surfaceY(atX: sample.x, z: sample.y)
                )
            }
        }
        let wallHeight = maxBoundarySurfaceY + baseDepth
        geometry.resampling = ResamplingParameters(
            baseDepth: baseDepth,
            wallHeight: wallHeight,
            sampleStep: cellSize
        )
        let cumulativeEdgeLengths = cumulativeLengths(of: boundary)
        let perimeter = boundary.perimeter
        // Repeat the wall texture around the perimeter so its texels stay roughly square.
        let wallURepeat = wallHeight > 0 ? max(1, (perimeter / wallHeight).rounded()) : 1

        func gridPoint(_ ix: Int, _ iz: Int) -> SIMD2<Float> {
            SIMD2(
                origin.x + Float(ix) * cellSize.x,
                origin.y + Float(iz) * cellSize.y
            )
        }

        // The vertex stays where the boundary put it; only what the terrain does there depends on
        // the pan offset.
        func topVertex(at point: SIMD2<Float>) -> (position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>) {
            let sample = point + panOffset
            let y = heightField.surfaceY(atX: sample.x, z: sample.y)
            let normal = surfaceNormal(heightField: heightField, at: sample, sampleStep: cellSize)
            return (
                SIMD3(point.x, y, point.y),
                normal,
                textureCoordinate(for: sample, heightField: heightField)
            )
        }

        func sharedTopIndex(_ ix: Int, _ iz: Int) -> UInt32 {
            let slot = iz * (cellsX + 1) + ix
            if topGridSlots[slot] >= 0 { return UInt32(topGridSlots[slot]) }
            let point = gridPoint(ix, iz)
            let vertex = topVertex(at: point)
            let index = geometry.top.addVertex(position: vertex.position, normal: vertex.normal, uv: vertex.uv)
            topGridSlots[slot] = Int32(index)
            return index
        }

        func sharedBottomIndex(_ ix: Int, _ iz: Int) -> UInt32 {
            let slot = iz * (cellsX + 1) + ix
            if bottomGridSlots[slot] >= 0 { return UInt32(bottomGridSlots[slot]) }
            let point = gridPoint(ix, iz)
            let index = geometry.bottom.addVertex(
                position: SIMD3(point.x, -baseDepth, point.y),
                normal: SIMD3(0, -1, 0),
                uv: textureCoordinate(for: point, heightField: heightField)
            )
            bottomGridSlots[slot] = Int32(index)
            return index
        }

        let emitsBottom = includesBottom && baseDepth > 0
        let emitsWalls = includesWalls && baseDepth + heightField.maxSurfaceY > 0

        for iz in 0..<cellsZ {
            let candidateEdges = edgesByRow[iz]

            for ix in 0..<cellsX {
                // Wound to match `DioramaBoundary`'s convention, so clipped cells fan into
                // upward-facing triangles and their boundary edges run in the same direction as
                // the boundary itself — which is what makes the wall normals face outward.
                let corners = [
                    gridPoint(ix, iz),
                    gridPoint(ix, iz + 1),
                    gridPoint(ix + 1, iz + 1),
                    gridPoint(ix + 1, iz),
                ]

                // Only edges that could actually cross this cell matter.
                let cellLo = corners[0]
                let cellHi = corners[2]
                let nearbyEdges = candidateEdges.filter { edgeIndex in
                    let bounds = boundary.edgeBounds(edgeIndex)
                    return bounds.hi.x >= cellLo.x - cellSize.x * 0.001
                        && bounds.lo.x <= cellHi.x + cellSize.x * 0.001
                }

                if nearbyEdges.isEmpty {
                    // Wholly inside or wholly outside — one containment test decides.
                    let center = (cellLo + cellHi) / 2
                    guard boundary.contains(center) else { continue }

                    let t0 = sharedTopIndex(ix, iz)
                    let t1 = sharedTopIndex(ix + 1, iz)
                    let t2 = sharedTopIndex(ix + 1, iz + 1)
                    let t3 = sharedTopIndex(ix, iz + 1)
                    geometry.top.addTriangle(t0, t3, t1)
                    geometry.top.addTriangle(t1, t3, t2)

                    if emitsBottom {
                        let b0 = sharedBottomIndex(ix, iz)
                        let b1 = sharedBottomIndex(ix + 1, iz)
                        let b2 = sharedBottomIndex(ix + 1, iz + 1)
                        let b3 = sharedBottomIndex(ix, iz + 1)
                        // Reversed winding so the face looks down.
                        geometry.bottom.addTriangle(b0, b1, b3)
                        geometry.bottom.addTriangle(b1, b2, b3)
                    }
                    continue
                }

                // The boundary crosses this cell, so intersect the two.
                //
                // Clip the *boundary* against the *cell* rather than the other way round.
                // Sutherland-Hodgman is exact whenever the clip region is convex, and a cell always
                // is; the boundary need not be. Clipping the cell against the boundary's edge
                // half-planes would instead intersect those half-planes, and at a reflex vertex the
                // interior spans more than 180°, so that intersection cuts away a wedge that
                // belongs to the chunk — leaving a notch at every concave corner.
                let cellEdges = [
                    (corners[0], corners[1]),
                    (corners[1], corners[2]),
                    (corners[2], corners[3]),
                    (corners[3], corners[0]),
                ]
                let weldDistance = min(cellSize.x, cellSize.y) * 1e-4
                let clipped = PolygonClipping.removingDuplicatePoints(
                    PolygonClipping.clip(polygon: boundary.vertices, against: cellEdges),
                    weldDistance: weldDistance
                )
                guard clipped.count >= 3, PolygonClipping.area(clipped) > cellSize.x * cellSize.y * 1e-5 else { continue }

                var topIndices: [UInt32] = []
                var bottomIndices: [UInt32] = []
                topIndices.reserveCapacity(clipped.count)

                for point in clipped {
                    let vertex = topVertex(at: point)
                    topIndices.append(geometry.top.addVertex(
                        position: vertex.position,
                        normal: vertex.normal,
                        uv: vertex.uv
                    ))
                    if emitsBottom {
                        bottomIndices.append(geometry.bottom.addVertex(
                            position: SIMD3(point.x, -baseDepth, point.y),
                            normal: SIMD3(0, -1, 0),
                            uv: textureCoordinate(for: point, heightField: heightField)
                        ))
                    }
                }

                // A cell containing a reflex vertex clips to a concave polygon, which a fan from
                // one vertex would triangulate incorrectly — it would span the notch.
                let minTriangleArea = cellSize.x * cellSize.y * 1e-6
                for triangle in PolygonClipping.triangulate(clipped, minimumArea: minTriangleArea) {
                    geometry.top.addTriangle(
                        topIndices[triangle.0],
                        topIndices[triangle.1],
                        topIndices[triangle.2]
                    )
                    if emitsBottom {
                        // Reversed winding so the face looks down.
                        geometry.bottom.addTriangle(
                            bottomIndices[triangle.0],
                            bottomIndices[triangle.2],
                            bottomIndices[triangle.1]
                        )
                    }
                }

                guard emitsWalls else { continue }

                // Any clipped edge lying on the boundary becomes a wall quad.
                for i in 0..<clipped.count {
                    let a = clipped[i]
                    let b = clipped[(i + 1) % clipped.count]
                    guard simd_distance(a, b) > cellSize.x * 1e-4 else { continue }
                    guard let edgeIndex = boundaryEdge(
                        containing: (a + b) / 2,
                        among: nearbyEdges,
                        boundary: boundary,
                        tolerance: max(cellSize.x, cellSize.y) * 1e-3
                    ) else { continue }

                    appendWallQuad(
                        from: a,
                        to: b,
                        boundaryEdgeIndex: edgeIndex,
                        boundary: boundary,
                        cumulativeEdgeLengths: cumulativeEdgeLengths,
                        perimeter: perimeter,
                        uRepeat: wallURepeat,
                        heightField: heightField,
                        panOffset: panOffset,
                        baseDepth: baseDepth,
                        wallHeight: wallHeight,
                        into: &geometry.walls
                    )
                }
            }
        }

        return geometry
    }

    // MARK: - Walls

    private static func appendWallQuad(
        from a: SIMD2<Float>,
        to b: SIMD2<Float>,
        boundaryEdgeIndex: Int,
        boundary: DioramaBoundary,
        cumulativeEdgeLengths: [Float],
        perimeter: Float,
        uRepeat: Float,
        heightField: TerrainHeightField,
        panOffset: SIMD2<Float>,
        baseDepth: Float,
        wallHeight: Float,
        into buffers: inout Buffers
    ) {
        let normal = DioramaBoundary.outwardNormal(forEdgeFrom: a, to: b)

        let sampleA = a + panOffset
        let sampleB = b + panOffset
        let yA = heightField.surfaceY(atX: sampleA.x, z: sampleA.y)
        let yB = heightField.surfaceY(atX: sampleB.x, z: sampleB.y)

        var uA = wallU(
            for: a,
            edgeIndex: boundaryEdgeIndex,
            boundary: boundary,
            cumulativeEdgeLengths: cumulativeEdgeLengths,
            perimeter: perimeter
        )
        var uB = wallU(
            for: b,
            edgeIndex: boundaryEdgeIndex,
            boundary: boundary,
            cumulativeEdgeLengths: cumulativeEdgeLengths,
            perimeter: perimeter
        )
        // Keep the quad from spanning the seam where the perimeter parameter wraps.
        if abs(uB - uA) > 0.5 {
            if uB > uA { uA += 1 } else { uB += 1 }
        }
        uA *= uRepeat
        uB *= uRepeat

        // A ridge cresting between sampled boundary points can sit slightly above the measured
        // wall height, so clamp rather than letting the texture coordinate run past its range.
        func v(_ y: Float) -> Float {
            wallHeight > 0 ? ((y + baseDepth) / wallHeight).clampedToUnitRange : 0
        }

        let aTop = buffers.addVertex(position: SIMD3(a.x, yA, a.y), normal: normal, uv: SIMD2(uA, v(yA)))
        let aBottom = buffers.addVertex(position: SIMD3(a.x, -baseDepth, a.y), normal: normal, uv: SIMD2(uA, 0))
        let bTop = buffers.addVertex(position: SIMD3(b.x, yB, b.y), normal: normal, uv: SIMD2(uB, v(yB)))
        let bBottom = buffers.addVertex(position: SIMD3(b.x, -baseDepth, b.y), normal: normal, uv: SIMD2(uB, 0))

        buffers.addTriangle(aTop, aBottom, bBottom)
        buffers.addTriangle(aTop, bBottom, bTop)
    }

    /// Perimeter position of a point lying on a known boundary edge, normalized to 0...1.
    private static func wallU(
        for point: SIMD2<Float>,
        edgeIndex: Int,
        boundary: DioramaBoundary,
        cumulativeEdgeLengths: [Float],
        perimeter: Float
    ) -> Float {
        guard perimeter > 0 else { return 0 }
        let (start, end) = boundary.edge(edgeIndex)
        let direction = end - start
        let lengthSquared = simd_length_squared(direction)
        let along: Float = lengthSquared > 0
            ? min(max(simd_dot(point - start, direction) / lengthSquared, 0), 1) * sqrt(lengthSquared)
            : 0
        return ((cumulativeEdgeLengths[edgeIndex] + along) / perimeter).clampedToUnitRange
    }

    private static func cumulativeLengths(of boundary: DioramaBoundary) -> [Float] {
        var lengths: [Float] = []
        lengths.reserveCapacity(boundary.edgeCount)
        var running: Float = 0
        for index in 0..<boundary.edgeCount {
            lengths.append(running)
            let (a, b) = boundary.edge(index)
            running += simd_distance(a, b)
        }
        return lengths
    }

    /// Returns the boundary edge a point lies on, if any.
    private static func boundaryEdge(
        containing point: SIMD2<Float>,
        among candidates: [Int],
        boundary: DioramaBoundary,
        tolerance: Float
    ) -> Int? {
        var best: Int?
        var bestDistance = tolerance
        for index in candidates {
            let distance = boundary.distance(from: point, toEdge: index)
            if distance <= bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    // MARK: - Clipping

    // MARK: - Support

    /// Groups boundary edges by the cell rows their Z range covers.
    private static func bucketEdgesByRow(
        boundary: DioramaBoundary,
        origin: SIMD2<Float>,
        cellSizeZ: Float,
        rowCount: Int
    ) -> [[Int]] {
        var buckets = [[Int]](repeating: [], count: rowCount)
        guard cellSizeZ > 0 else { return buckets }

        for edgeIndex in 0..<boundary.edgeCount {
            let bounds = boundary.edgeBounds(edgeIndex)
            let firstRow = max(0, Int(floor((bounds.lo.y - origin.y) / cellSizeZ)) - 1)
            let lastRow = min(rowCount - 1, Int(ceil((bounds.hi.y - origin.y) / cellSizeZ)) + 1)
            guard firstRow <= lastRow else { continue }
            for row in firstRow...lastRow {
                buckets[row].append(edgeIndex)
            }
        }
        return buckets
    }

    /// Surface normal from central differences on the height field, so shading stays smooth
    /// across cell boundaries even though neighbouring cells may not share vertices.
    private static func surfaceNormal(
        heightField: TerrainHeightField,
        at point: SIMD2<Float>,
        sampleStep: SIMD2<Float>
    ) -> SIMD3<Float> {
        let dx = max(sampleStep.x, 1e-6)
        let dz = max(sampleStep.y, 1e-6)

        let yLeft = heightField.surfaceY(atX: point.x - dx, z: point.y)
        let yRight = heightField.surfaceY(atX: point.x + dx, z: point.y)
        let yBack = heightField.surfaceY(atX: point.x, z: point.y - dz)
        let yFront = heightField.surfaceY(atX: point.x, z: point.y + dz)

        let slopeX = (yRight - yLeft) / (2 * dx)
        let slopeZ = (yFront - yBack) / (2 * dz)

        return simd_normalize(SIMD3(-slopeX, 1, -slopeZ))
    }

    /// Maps a diorama-space X/Z position into the satellite imagery's 0...1 texture space.
    private static func textureCoordinate(
        for point: SIMD2<Float>,
        heightField: TerrainHeightField
    ) -> SIMD2<Float> {
        SIMD2(
            ((point.x + heightField.extent.x / 2) / heightField.extent.x).clampedToUnitRange,
            ((point.y + heightField.extent.y / 2) / heightField.extent.y).clampedToUnitRange
        )
    }

    @MainActor
    private static func buildMesh(from buffers: Buffers, name: String) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(buffers.positions)
        descriptor.normals = MeshBuffers.Normals(buffers.normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(buffers.uvs)
        descriptor.primitives = .triangles(buffers.indices)

        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            throw DioramaError.meshGenerationFailed(reason: error.localizedDescription)
        }
    }
}
