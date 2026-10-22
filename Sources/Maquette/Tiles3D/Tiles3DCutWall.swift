import Foundation
import RealityKit
import simd

/// A segment of a clipped tile's silhouette that lies on the diorama's outline.
///
/// Recorded during clipping rather than recovered afterwards, because that is the only moment the
/// information is free: the clipper already knows which of an output polygon's edges it created by
/// cutting, and recovering them later would mean re-deriving the silhouette of arbitrary
/// photogrammetry triangle soup.
struct Tiles3DCutEdge: Sendable, Equatable {
    /// Endpoints in the geometry's own space, with the tile's placement already baked in — the same
    /// space the clipped mesh ends up in, so the wall needs no transform of its own.
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    /// The boundary edge the segment lies along.
    ///
    /// Carried rather than looked up again so the wall can take its outward normal from the outline
    /// instead of from the segment. Photogrammetry winding is arbitrary — facades face both ways —
    /// so a normal derived from the cut segment's own direction points outward only by luck.
    var boundaryEdge: Int
}

/// The cut edges a loaded tile contributed, kept on the tile's own entity.
///
/// Attaching them to the entity rather than tracking them alongside means they follow the tile
/// through the level-of-detail manager's showing and hiding for free: the wall is rebuilt from
/// whatever is enabled, so a tile that gets superseded stops contributing the moment it is hidden.
struct Tiles3DCutEdgeComponent: Component {
    var edges: [Tiles3DCutEdge]
}

/// Registration for the component above. A `static let` so it runs exactly once.
@MainActor
enum Tiles3DCutEdgeRegistration {
    static let perform: Void = {
        Tiles3DCutEdgeComponent.registerComponent()
    }()
}

/// Builds the cut wall closing a photorealistic model's sliced edge.
///
/// A bounded skirt closes each cut segment against the surface-following underside. Both use
/// the same vertical displacement, preserving the source terrain instead of flattening it to fit
/// a tray. Photogrammetry remains arbitrary triangle soup: this does not repair holes or infer
/// manifold solids from open input geometry.
enum Tiles3DCutWall {
    /// Raw buffers, separated from mesh creation so the geometry can be exercised without a
    /// RealityKit device context.
    ///
    /// Packed into the same vertex layout the tiles use, so the wall reaches the GPU the same way
    /// they do — as a bulk copy into a buffer that outlives the pan step.
    struct Geometry {
        var vertices: [Tiles3DVertex] = []
        var indices: [UInt32] = []
        /// Accumulated as the wall is emitted, so nothing has to walk it again to find them.
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        var isEmpty: Bool { indices.isEmpty }
        var bounds: BoundingBox { BoundingBox(min: lower, max: upper) }
    }

    /// Extrudes cut edges downward into a wall.
    ///
    /// - Parameters:
    ///   - edges: Silhouette segments gathered from every tile currently on screen.
    ///   - floorY: Lowest permitted underside height in the geometry's space.
    ///   - maximumThickness: Additional ceiling on skirt thickness, in geometry-space metres.
    ///     The outline's own ten-percent limit always applies.
    ///   - prism: The outline the model was cut to, for perimeter texturing and outward normals.
    /// - Returns: The wall's buffers, or `nil` when there is nothing to build.
    static func buildGeometry(
        edges: [Tiles3DCutEdge],
        floorY: Float,
        prism: BoundaryPrism,
        maximumThickness: Float? = nil
    ) -> Geometry? {
        guard !edges.isEmpty else { return nil }

        // Anything already at or below the floor has no wall to contribute.
        let standing = edges.filter { max($0.a.y, $0.b.y) > floorY }
        guard !standing.isEmpty else { return nil }

        let limit = min(maximumThickness ?? .infinity, ChunkThicknessLimit.maximum(for: prism.boundary))
        guard limit.isFinite, limit > 0 else { return nil }
        let wallHeight = min(referenceHeight(of: standing, above: floorY), limit)
        guard wallHeight > 0 else { return nil }

        let perimeter = prism.perimeter
        // Repeat the strata around the perimeter so its texels stay roughly square, matching what
        // the raster chunk's walls do.
        let uRepeat = perimeter > 0 ? max(1, (perimeter / wallHeight).rounded()) : 1

        var geometry = Geometry()
        geometry.vertices.reserveCapacity(standing.count * 4)
        geometry.indices.reserveCapacity(standing.count * 6)

        for edge in standing {
            guard prism.boundary.vertices.indices.contains(edge.boundaryEdge) else { continue }
            let (start, end) = prism.boundary.edge(edge.boundaryEdge)
            let normal = DioramaBoundary.outwardNormal(forEdgeFrom: start, to: end)

            // Ordered along the boundary rather than along the source triangle, so every quad winds
            // the same way regardless of which direction the photogrammetry happened to run.
            var a = edge.a
            var b = edge.b
            if simd_dot(SIMD2(b.x - a.x, b.z - a.z), end - start) < 0 {
                swap(&a, &b)
            }

            var uA = prism.perimeterPosition(of: SIMD2(a.x, a.z), onEdge: edge.boundaryEdge)
            var uB = prism.perimeterPosition(of: SIMD2(b.x, b.z), onEdge: edge.boundaryEdge)
            // Keep a quad from spanning the seam where the perimeter parameter wraps.
            if abs(uB - uA) > 0.5 {
                if uB > uA { uA += 1 } else { uB += 1 }
            }
            uA *= uRepeat
            uB *= uRepeat

            func bottom(_ y: Float) -> Float { max(floorY, y - limit) }
            // Geometry-space elevation is stable across pans and LOD changes. A per-cut
            // 0...1 mapping gives overlapping/adjacent source layers different strata phases.
            func v(_ y: Float) -> Float { y / limit }

            let base = UInt32(geometry.vertices.count)
            append(&geometry, SIMD3(a.x, max(a.y, floorY), a.z), normal, SIMD2(uA, v(a.y)))
            append(&geometry, SIMD3(a.x, bottom(a.y), a.z), normal, SIMD2(uA, v(bottom(a.y))))
            append(&geometry, SIMD3(b.x, max(b.y, floorY), b.z), normal, SIMD2(uB, v(b.y)))
            append(&geometry, SIMD3(b.x, bottom(b.y), b.z), normal, SIMD2(uB, v(bottom(b.y))))

            geometry.indices.append(base)
            geometry.indices.append(base + 1)
            geometry.indices.append(base + 3)
            geometry.indices.append(base)
            geometry.indices.append(base + 3)
            geometry.indices.append(base + 2)
        }

        return geometry.isEmpty ? nil : geometry
    }

    /// Rebuilds the wall into a buffer the renderer is already drawing from.
    ///
    /// A pan retires the wall and asks for it again, so this runs as often as the re-cut does and
    /// must not compile an asset to do it — see `Tiles3DMeshBuffer`.
    ///
    /// - Returns: What the write left behind, or `.empty` when there is no wall to build.
    @MainActor
    static func write(
        edges: [Tiles3DCutEdge],
        floorY: Float,
        prism: BoundaryPrism,
        maximumThickness: Float? = nil,
        into buffer: Tiles3DMeshBuffer
    ) throws -> Tiles3DMeshBuffer.Outcome {
        guard let geometry = buildGeometry(edges: edges, floorY: floorY, prism: prism, maximumThickness: maximumThickness) else {
            return .empty
        }
        return try buffer.write(
            vertices: geometry.vertices,
            indices: geometry.indices,
            bounds: geometry.bounds
        )
    }

    // MARK: - Private

    private static func append(
        _ geometry: inout Geometry,
        _ position: SIMD3<Float>,
        _ normal: SIMD3<Float>,
        _ uv: SIMD2<Float>
    ) {
        geometry.vertices.append(Tiles3DVertex(position: position, normal: normal, uv: uv))
        geometry.lower = simd_min(geometry.lower, position)
        geometry.upper = simd_max(geometry.upper, position)
    }

    /// The vertical span the strata are normalized against.
    ///
    /// Not the tallest edge. In a city the outline cuts through buildings, and a single tower on the
    /// rim would stretch every band on every other wall down into a sliver to make room for it. A
    /// high percentile tracks the ground the wall is mostly made of and lets the rare outlier clamp
    /// at the top band instead — which reads as a facade standing above the earth, roughly what it
    /// is.
    private static func referenceHeight(of edges: [Tiles3DCutEdge], above floorY: Float) -> Float {
        let tops = edges.map { max($0.a.y, $0.b.y) - floorY }.sorted()
        let index = min(tops.count - 1, Int(Float(tops.count - 1) * 0.9))
        return tops[index]
    }
}
