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
/// The clipper leaves cut faces open, on the reasoning that the tray beneath hides them. That holds
/// only while the model's relief is small next to the tray: on Half Dome the outline crosses
/// roughly 1,480 m of terrain against a tray around 87 m thick in the same space, so the tray hides
/// nothing and the model reads as a hollow shell — which contradicts the whole library's first
/// premise, that a chunk is a solid.
///
/// So the silhouette is extruded down to the same level the tray's top sits at, and textured with
/// the same procedural strata the raster chunk's walls use. The two pipelines stay separate, but
/// the cut edge is the one place where the vocabularies genuinely coincide: both are a slice
/// through ground, and both should look like one.
enum Tiles3DCutWall {
    /// Raw buffers, separated from mesh creation so the geometry can be exercised without a
    /// RealityKit device context.
    struct Geometry {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        var isEmpty: Bool { indices.isEmpty }
    }

    /// Extrudes cut edges downward into a wall.
    ///
    /// - Parameters:
    ///   - edges: Silhouette segments gathered from every tile currently on screen.
    ///   - floorY: Where the wall stops, in the geometry's space. The tray's top, so the two meet.
    ///   - prism: The outline the model was cut to, for perimeter texturing and outward normals.
    /// - Returns: The wall's buffers, or `nil` when there is nothing to build.
    static func buildGeometry(
        edges: [Tiles3DCutEdge],
        floorY: Float,
        prism: BoundaryPrism
    ) -> Geometry? {
        guard !edges.isEmpty else { return nil }

        // Anything already at or below the floor has no wall to contribute.
        let standing = edges.filter { max($0.a.y, $0.b.y) > floorY }
        guard !standing.isEmpty else { return nil }

        let wallHeight = referenceHeight(of: standing, above: floorY)
        guard wallHeight > 0 else { return nil }

        let perimeter = prism.perimeter
        // Repeat the strata around the perimeter so its texels stay roughly square, matching what
        // the raster chunk's walls do.
        let uRepeat = perimeter > 0 ? max(1, (perimeter / wallHeight).rounded()) : 1

        var geometry = Geometry()
        geometry.positions.reserveCapacity(standing.count * 4)
        geometry.normals.reserveCapacity(standing.count * 4)
        geometry.uvs.reserveCapacity(standing.count * 4)
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

            func v(_ y: Float) -> Float {
                ((y - floorY) / wallHeight).clampedToUnitRange
            }

            let base = UInt32(geometry.positions.count)
            append(&geometry, SIMD3(a.x, max(a.y, floorY), a.z), normal, SIMD2(uA, v(a.y)))
            append(&geometry, SIMD3(a.x, floorY, a.z), normal, SIMD2(uA, 0))
            append(&geometry, SIMD3(b.x, max(b.y, floorY), b.z), normal, SIMD2(uB, v(b.y)))
            append(&geometry, SIMD3(b.x, floorY, b.z), normal, SIMD2(uB, 0))

            geometry.indices.append(contentsOf: [base, base + 1, base + 3])
            geometry.indices.append(contentsOf: [base, base + 3, base + 2])
        }

        return geometry.isEmpty ? nil : geometry
    }

    /// Builds the wall as a renderable entity.
    ///
    /// - Returns: The wall, or `nil` when the style asks for none or nothing survives.
    @MainActor
    static func generate(
        edges: [Tiles3DCutEdge],
        floorY: Float,
        prism: BoundaryPrism,
        style: ChunkWallStyle
    ) throws -> ModelEntity? {
        guard let material = DioramaMaterials.wallMaterial(for: style),
              let geometry = buildGeometry(edges: edges, floorY: floorY, prism: prism) else {
            return nil
        }

        var descriptor = MeshDescriptor(name: "tiles3DCutWall")
        descriptor.positions = MeshBuffers.Positions(geometry.positions)
        descriptor.normals = MeshBuffers.Normals(geometry.normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(geometry.uvs)
        descriptor.primitives = .triangles(geometry.indices)

        let mesh = try MeshResource.generate(from: [descriptor])
        return ModelEntity(mesh: mesh, materials: [material])
    }

    // MARK: - Private

    private static func append(
        _ geometry: inout Geometry,
        _ position: SIMD3<Float>,
        _ normal: SIMD3<Float>,
        _ uv: SIMD2<Float>
    ) {
        geometry.positions.append(position)
        geometry.normals.append(normal)
        geometry.uvs.append(uv)
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
