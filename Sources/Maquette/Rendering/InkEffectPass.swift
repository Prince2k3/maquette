import CoreGraphics
import Foundation
import os
import RealityKit
import simd

/// Draws the chunk as an illustration: black outlines along every hard edge, flat cel-shaded colour
/// between them, and the earth beneath reduced to a plain grey block.
///
/// The lines are geometry, for the reason `HologramEffectPass` documents at length — `CustomMaterial`
/// is unavailable on visionOS, `ShaderGraphMaterial` only loads from a Reality Composer Pro asset
/// this package ships none of, and RealityKit exposes no cross-platform post-process — so the usual
/// way of drawing outlines, a depth-and-normal edge detect over the framebuffer, is not available on
/// all four platforms. What is available is that the chunk's own triangles already know where its
/// edges are, and they know it more exactly than a screen-space filter would: a *border* edge has one
/// triangle and is therefore the cut outline, concave corners and all, and a *crease* edge has two
/// that disagree sharply about which way the surface faces, which is a cliff or a ridge.
///
/// What that does not give is an outline where one piece of geometry occludes another without
/// touching it — a tower drawn against the ground behind it. That is genuinely a screen-space
/// question, and it is the part of the reference look this cannot reach.
@MainActor
final class InkEffectPass: DioramaEffectPass {
    private static let logger = Logger(subsystem: "com.maquette", category: "InkEffect")

    private let style: InkStyle

    private var body = EffectBody()
    private var container: Entity?
    private var lines: EffectLayer?

    /// Reused between refreshes so a pan step does not reallocate the whole line set.
    private var lineMesh = IndexedMesh()

    /// The surface's edge structure, built once.
    ///
    /// A pan changes heights, normals and texture coordinates, never topology or horizontal position,
    /// so which vertices are adjacent to which is settled the moment the effect goes on. Only the
    /// dihedral test has to run again, because the heights either side of an edge are re-sampled and
    /// a ridge that was sharp under one stretch of ground is smooth under the next.
    private var edges: MeshEdges?

    /// For each inked corner of the outline, the surface vertex standing at it.
    ///
    /// Resolved once for the same reason, and read back on every step for the corner's upper end.
    private var cornerVertices: [Int] = []
    private var cornerPoints: [SIMD2<Float>] = []

    /// How far below Y = 0 the block's lower rim is drawn, measured at `apply`.
    private var baseDepth: Float = 0

    /// The tonal range the imagery is banded against, measured from the first mosaic and then held.
    ///
    /// Frozen for the same reason the wall texture's vertical reference is: a roll brings in ground
    /// that is brighter or darker than the ground it replaces, and re-measuring would repaint every
    /// band in the picture at the moment new tiles landed.
    private var tones: InkImagery.Tones?

    /// How close two surface vertices must be to count as the same point, as a fraction of the
    /// chunk's largest extent.
    ///
    /// Wants to be far below the sampling grid's spacing — which at 256 cells across is about 0.004
    /// of the extent — and far above the rounding error a boundary clip introduces. Two orders of
    /// magnitude of daylight either side.
    private static let weldTolerance: Float = 1e-5

    init(style: InkStyle) {
        self.style = style
    }

    func apply(to root: DioramaEntity, context: DioramaEffectContext) {
        guard let terrain = root.terrain, let surface = terrain.surfaceBuffers else {
            Self.logger.info(
                """
                The ink effect needs a raster terrain chunk and this diorama has none; \
                leaving it as it is
                """
            )
            return
        }

        baseDepth = terrain.baseDepth
        restyleBody(of: root, context: context)

        let extent = max(context.boundary.extent.x, context.boundary.extent.y)
        edges = MeshEdges(
            positions: surface.positions,
            indices: surface.indices,
            tolerance: extent * Self.weldTolerance
        )

        let corners = InkGeometry.cornerIndices(
            of: context.boundary.vertices,
            minimumAngle: style.cornerAngle * .pi / 180
        )
        cornerPoints = corners.map { context.boundary.vertices[$0] }
        cornerVertices = InkGeometry.nearestVertices(to: cornerPoints, in: surface.positions)

        let container = Entity()
        container.name = "InkEffect"
        terrain.addChild(container)
        self.container = container

        let lines = EffectLayer(
            name: "InkLines",
            material: DioramaMaterials.inkLineMaterial(color: style.lineColor)
        )
        container.addChild(lines.entity)
        self.lines = lines

        refresh(on: root, context: context)
    }

    func refresh(on root: DioramaEntity, context: DioramaEffectContext) {
        // `edges` is deliberately not bound here. It carries a face-normal buffer the size of the
        // surface that the crease test rewrites in place, and a local copy would leave the property
        // holding a second reference to it — so every step would pay to copy it before writing.
        guard let lines, edges != nil else { return }
        guard let surface = root.terrain?.surfaceBuffers else { return }

        let extent = max(context.boundary.extent.x, context.boundary.extent.y)
        let radius = style.lineWidth * extent / 2
        guard radius > 0 else {
            lines.clear()
            return
        }

        lineMesh.removeAll()

        // The rim and the creases in one layer and one draw, because they are the same kind of mark:
        // the reference draws no distinction between the line around a shape and the line across it.
        InkGeometry.addTubes(edges?.borders(in: surface.positions) ?? [], radius: radius, into: &lineMesh)
        let creaseSegments = edges?.creases(
            in: surface.positions,
            minimumAngle: style.creaseAngle * .pi / 180,
            density: style.creaseDensity
        ) ?? []
        InkGeometry.addTubes(creaseSegments, radius: radius, into: &lineMesh)

        // The block's own edges: a vertical line down each corner of the outline, and a loop around
        // the bottom face. The lower rim is flat and fixed, so unlike everything above it a pan does
        // not move it — but it costs one loop of the outline to rebuild and keeping it in a second
        // layer to avoid that would cost a second draw.
        InkGeometry.addTubes(cornerSegments(in: surface.positions), radius: radius, into: &lineMesh)
        if baseDepth > 0 {
            InkGeometry.addTubes(
                HologramGeometry.loop(context.boundary.vertices, y: -baseDepth),
                radius: radius,
                into: &lineMesh
            )
        }

        lines.update(with: lineMesh)
        Self.logger.debug("Ink step: \(creaseSegments.count) creases, \(self.lineMesh.vertices.count) vertices")
    }

    func reapply(to root: DioramaEntity, context: DioramaEffectContext) {
        guard container != nil else { return }
        // Forget what was saved before repainting, so what the effect hands back on revert is the
        // imagery the chunk has now rather than the window it was showing when the effect went on.
        body.forgetMaterials()
        restyleBody(of: root, context: context)
        refresh(on: root, context: context)
    }

    func revert(from root: DioramaEntity) {
        container?.removeFromParent()
        container = nil
        lines = nil
        edges = nil
        cornerVertices.removeAll()
        cornerPoints.removeAll()
        tones = nil
        body.restore()
    }

    // MARK: - Lines

    /// A vertical line down each corner of the outline, from the terrain to the block's bottom.
    private func cornerSegments(in positions: [SIMD3<Float>]) -> [ContourExtractor.Segment] {
        guard baseDepth > 0 else { return [] }
        return zip(cornerPoints, cornerVertices).compactMap { point, vertex in
            guard positions.indices.contains(vertex) else { return nil }
            return ContourExtractor.Segment(
                a: SIMD3(point.x, positions[vertex].y, point.y),
                b: SIMD3(point.x, -baseDepth, point.y)
            )
        }
    }

    // MARK: - Body

    /// Repaints the solid the lines are drawn over, saving what it replaces.
    private func restyleBody(of root: DioramaEntity, context: DioramaEffectContext) {
        // The strata go. They are the one part of a chunk that is invented rather than measured, and
        // the reference draws the block they describe as a plain solid — the form of it comes from
        // the lines around it, not from anything painted on its faces.
        body.replaceEarth(of: root, with: DioramaMaterials.inkFlatMaterial(color: style.blockColor))

        if let water = root.waterPlane as? ModelEntity {
            body.replace(water, with: DioramaMaterials.inkFlatMaterial(color: style.waterColor))
        }

        body.replace(root.terrain?.surface, with: surfaceMaterial(context: context))
    }

    /// The imagery, flattened — or a flat colour when there is none to flatten.
    ///
    /// Falling back rather than failing is the point of the ordering here. `showsImagery` off, no
    /// mosaic in hand, and a mosaic that will not posterize all want the same answer, and the one
    /// thing none of them should produce is a chunk still wearing continuous-tone photography under
    /// a set of ink lines, which reads as a bug rather than as a treatment.
    private func surfaceMaterial(context: DioramaEffectContext) -> any RealityKit.Material {
        let flat = DioramaMaterials.inkFlatMaterial(color: style.surfaceColor)
        guard style.showsImagery, let imagery = context.imagery else { return flat }

        do {
            let posterized = try InkImagery.posterize(
                imagery,
                recipe: InkImagery.Recipe(
                    patchSize: style.patchSize,
                    levels: style.colorLevels,
                    saturation: style.saturation
                ),
                tones: tones
            )
            tones = posterized.tones
            return try DioramaMaterials.inkSurfaceMaterial(from: posterized.image)
        } catch {
            Self.logger.error("Could not flatten the chunk's imagery, painting it flat: \(error)")
            return flat
        }
    }
}
