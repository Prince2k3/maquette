import Foundation
import RealityKit
import os
import simd

/// Turns OpenStreetMap building footprints into extruded blocks standing on the chunk's terrain.
///
/// ## Why buildings come from a separate source at all
///
/// The chunk's own surface cannot carry them. Both elevation providers are bare-earth models —
/// Mapzen Terrarium and MapTiler terrain-rgb both describe the ground with structures removed — and
/// even if they did not, a heightfield holds one Y per horizontal position, so it cannot express a
/// vertical wall. Buildings are additional geometry resting on the terrain, not detail within it.
///
/// ## What is deliberately approximate
///
/// A footprint's base sits at the **lowest** terrain sample under its outline, not at each corner's
/// own height. Following the ground per-corner would shear the walls; taking the mean would sink the
/// downhill side into the hill. Taking the minimum means a building on a slope stands on its lowest
/// corner and floats slightly at its highest, which reads correctly from every angle a diorama is
/// looked at, and the error is bounded by the relief across one footprint — a few meters at most.
enum BuildingExtruder {
    private static let logger = Logger(subsystem: "com.maquette", category: "Buildings")

    /// The geometry produced for one region's buildings, plus what it took to get there.
    struct Result {
        /// The extruded blocks, ready for `Tiles3DMeshBuffer`.
        var mesh: IndexedMesh
        /// How many footprints became geometry.
        var kept: Int
        /// How many were dropped for crossing or lying outside the chunk's outline.
        var droppedOutside: Int
        /// How many were dropped because their outline could not be triangulated.
        var droppedDegenerate: Int
    }

    /// Extrudes every footprint that lies wholly inside the chunk's outline.
    ///
    /// Footprints that cross the outline are dropped rather than clipped. Clipping them correctly
    /// would mean clipping *against* a boundary that may be concave, and Sutherland-Hodgman is exact
    /// only when the clip region is convex — the same trap `TerrainSolidGenerator` documents, where
    /// intersecting a concave outline's edge half-planes punches a notch at every reflex corner. The
    /// exact answer exists (clip the boundary against each footprint, as the terrain does per cell)
    /// but a building straddling the rim is a rare enough case that dropping it costs less than the
    /// machinery to keep it.
    ///
    /// - Parameters:
    ///   - footprints: Footprints in geographic coordinates.
    ///   - heightField: Supplies both the ground under each footprint and the geographic mapping.
    ///   - boundary: The chunk's outline. Footprints not wholly inside it are dropped.
    ///   - style: Height defaults and the vertical scale to draw at.
    static func extrude(
        footprints: [BuildingFootprint],
        heightField: TerrainHeightField,
        boundary: DioramaBoundary,
        style: BuildingStyle
    ) -> Result {
        var result = Result(mesh: IndexedMesh(), kept: 0, droppedOutside: 0, droppedDegenerate: 0)

        // A typical footprint is a quad: 4 side quads plus a roof fan is about 20 vertices.
        result.mesh.reserve(vertices: footprints.count * 20, indices: footprints.count * 54)

        let anchor = heightField.anchor
        var outline: [SIMD2<Float>] = []

        for footprint in footprints {
            outline.removeAll(keepingCapacity: true)
            outline.reserveCapacity(footprint.outline.count)

            var inside = true
            for coordinate in footprint.outline {
                let point = anchor.dioramaPoint(for: coordinate)
                let planar = SIMD2(Float(point.x), Float(point.y))
                if !boundary.contains(planar) {
                    inside = false
                    break
                }
                outline.append(planar)
            }
            guard inside else {
                result.droppedOutside += 1
                continue
            }

            let height = Float(footprint.heightMeters) * style.verticalScale(of: heightField)
            if addBlock(outline, height: max(height, style.minimumDrawnHeight),
                        heightField: heightField, into: &result.mesh) {
                result.kept += 1
            } else {
                result.droppedDegenerate += 1
            }
        }

        if result.droppedOutside > 0 || result.droppedDegenerate > 0 {
            logger.info(
                """
                Extruded \(result.kept) buildings; dropped \(result.droppedOutside) crossing the \
                outline and \(result.droppedDegenerate) that would not triangulate
                """
            )
        }
        return result
    }

    /// Adds one footprint's walls and roof. Returns `false` if the outline is degenerate.
    ///
    /// OSM stores rings in whichever direction the mapper drew them, so the ring is first turned to
    /// match `DioramaBoundary`'s winding. Everything downstream then gets what it already assumes:
    /// `PolygonClipping.triangulate` preserves the winding it is given, so the roof comes out facing
    /// up, and `DioramaBoundary.outwardNormal(forEdgeFrom:to:)` names the wall normals correctly.
    static func addBlock(
        _ footprint: [SIMD2<Float>],
        height: Float,
        heightField: TerrainHeightField,
        into mesh: inout IndexedMesh
    ) -> Bool {
        guard footprint.count >= 3 else { return false }

        let outline = PolygonClipping.signedArea(footprint) > 0
            ? footprint.reversed().map { $0 }
            : footprint

        let triangles = PolygonClipping.triangulate(outline, minimumArea: 0)
        guard !triangles.isEmpty else { return false }

        // The base is the lowest ground under the footprint, so a building on a slope is buried at
        // its uphill corner rather than hovering at its downhill one.
        var baseY = Float.greatestFiniteMagnitude
        for point in outline {
            baseY = min(baseY, heightField.surfaceY(atX: point.x, z: point.y))
        }
        // Sunk a little, so the seam where a wall meets the terrain is never a visible gap on
        // ground that undulates between the sampled corners.
        baseY -= height * 0.02
        let topY = baseY + height

        addWalls(outline, baseY: baseY, topY: topY, into: &mesh)
        addRoof(outline, triangles: triangles, y: topY, into: &mesh)
        return true
    }

    private static func addWalls(
        _ outline: [SIMD2<Float>],
        baseY: Float,
        topY: Float,
        into mesh: inout IndexedMesh
    ) {
        for i in outline.indices {
            let a = outline[i]
            let b = outline[(i + 1) % outline.count]
            guard simd_distance(a, b) > 1e-7 else { continue }
            let outward = DioramaBoundary.outwardNormal(forEdgeFrom: a, to: b)

            // Same vertex order and diagonal as `TerrainSolidGenerator.appendWallQuad`, so a cut
            // wall and a building wall wind the same way.
            let aTop = mesh.append(
                position: SIMD3(a.x, topY, a.y), normal: outward, uv: SIMD2(0, 1))
            let aBottom = mesh.append(
                position: SIMD3(a.x, baseY, a.y), normal: outward, uv: SIMD2(0, 0))
            let bTop = mesh.append(
                position: SIMD3(b.x, topY, b.y), normal: outward, uv: SIMD2(1, 1))
            let bBottom = mesh.append(
                position: SIMD3(b.x, baseY, b.y), normal: outward, uv: SIMD2(1, 0))

            mesh.appendTriangle(aTop, aBottom, bBottom)
            mesh.appendTriangle(aTop, bBottom, bTop)
        }
    }

    private static func addRoof(
        _ outline: [SIMD2<Float>],
        triangles: [(Int, Int, Int)],
        y: Float,
        into mesh: inout IndexedMesh
    ) {
        let up = SIMD3<Float>(0, 1, 0)
        var base: [UInt32] = []
        base.reserveCapacity(outline.count)
        for point in outline {
            base.append(mesh.append(position: SIMD3(point.x, y, point.y), normal: up, uv: point))
        }
        for (a, b, c) in triangles {
            mesh.appendTriangle(base[a], base[b], base[c])
        }
    }
}
