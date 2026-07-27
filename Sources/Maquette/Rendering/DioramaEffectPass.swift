import Foundation
import os
import RealityKit
import SwiftUI
import simd

/// What an effect needs to know about the diorama it is restyling.
///
/// Deliberately small: an effect reads the finished scene rather than the pipeline that built it,
/// and everything here is either fixed at load or carried on the entities themselves.
struct DioramaEffectContext {
    /// The chunk's outline in the horizontal plane.
    let boundary: DioramaBoundary
    /// Diorama meters of height per real meter of elevation, exaggeration included.
    let elevationScale: Float
    /// The real elevation that diorama Y = 0 stands for.
    let baselineElevation: Float
}

/// A restyle of a built diorama.
///
/// Four verbs rather than one, because they happen at different rates and mean different things.
/// `apply` runs when the effect is switched on and `refresh` on every pan step, once the terrain
/// beneath the outline has moved. `revert` has to put back exactly what `apply` replaced — an effect
/// that could only be added would make `.none` mean "reload the diorama". And `reapply` covers the
/// case where the scene changed its own materials underneath the effect, which a rolling fetch does
/// every time it lands: reverting and re-applying there would hand the chunk back the *previous*
/// window's imagery.
@MainActor
protocol DioramaEffectPass: AnyObject {
    func apply(to root: DioramaEntity, context: DioramaEffectContext)
    func refresh(on root: DioramaEntity, context: DioramaEffectContext)
    func reapply(to root: DioramaEntity, context: DioramaEffectContext)
    func revert(from root: DioramaEntity)
}

extension DioramaEffect {
    /// Builds the pass that realizes this effect, or `nil` when there is nothing to do.
    @MainActor
    func makePass() -> (any DioramaEffectPass)? {
        switch kind {
        case .none:
            return nil
        case .hologram(let style):
            return HologramEffectPass(style: style)
        }
    }
}

// MARK: - Hologram

/// Paints the chunk as a projected volume: a dark, near-unlit body with glowing elevation contours
/// and a graticule traced across it.
///
/// The lines are geometry. `CustomMaterial` is unavailable on visionOS and `ShaderGraphMaterial`
/// only loads from a Reality Composer Pro asset, which this package ships none of, so a shader that
/// drew contours from the surface's own height would render on three platforms out of four. Tracing
/// them as triangles renders on all four, and comes with a property a shader would have had to be
/// given separately: the isolines are extracted from the chunk's own clipped triangles, so they stop
/// exactly on the cut edge, concave outlines included.
@MainActor
final class HologramEffectPass: DioramaEffectPass {
    private static let logger = Logger(subsystem: "com.maquette", category: "HologramEffect")

    private let style: HologramStyle

    /// Materials displaced by the effect, so `revert` can put the original diorama back.
    private var savedMaterials: [ObjectIdentifier: [any RealityKit.Material]] = [:]
    private var hiddenEntities: [Entity] = []

    private var container: Entity?
    private var glow: HologramLayer?
    private var core: HologramLayer?
    private var graticule: HologramLayer?
    private var plate: HologramLayer?
    private var rings: HologramLayer?
    private var beam: HologramLayer?

    /// Reused between refreshes so a pan step does not reallocate the whole line set.
    private var glowMesh = HologramMesh()
    private var coreMesh = HologramMesh()
    private var graticuleMesh = HologramMesh()

    private var graticuleLines: [ContourExtractor.Segment] = []

    /// How the graticule is weighted against the contours.
    ///
    /// It is deliberately not a style knob. The graticule is a ruling the terrain is read *against* —
    /// drawn at the contours' own weight it competes with them, and on a region with real relief the
    /// two sets cross often enough that the topography stops being legible at all. Its job is to give
    /// the eye a frame, so it is thinner, dimmer, and carries no halo of its own.
    private static let graticuleWidthFactor: Float = 0.5
    private static let graticuleOpacity: Float = 0.3

    /// How much wider than the chunk the pedestal's plate is drawn.
    ///
    /// Wider on purpose. A plate exactly the chunk's own size is hidden by the chunk from every
    /// angle above the horizon, which is every angle anyone actually looks from — the projection
    /// would go back to hanging from nothing for all the geometry it cost.
    private static let plateScale: Float = 1.10

    /// How far in from the plate's rim the innermost ring is drawn, as a fraction of the plate.
    private static let innermostRing: Float = 0.55

    init(style: HologramStyle) {
        self.style = style
    }

    func apply(to root: DioramaEntity, context: DioramaEffectContext) {
        guard let terrain = root.terrain else {
            Self.logger.info(
                """
                The hologram effect needs a raster terrain chunk and this diorama has none; \
                leaving it as it is
                """
            )
            return
        }

        restyleBody(of: root)

        let container = Entity()
        container.name = "HologramEffect"
        terrain.addChild(container)
        self.container = container

        // Wide and faint first, so the core draws over its own halo.
        let glow = HologramLayer(
            name: "HologramGlow",
            material: DioramaMaterials.hologramLineMaterial(
                color: style.tint,
                opacity: style.glowOpacity
            )
        )
        let graticule = HologramLayer(
            name: "HologramGraticule",
            material: DioramaMaterials.hologramLineMaterial(
                color: style.tint,
                opacity: Self.graticuleOpacity
            )
        )
        let core = HologramLayer(
            name: "HologramLines",
            material: DioramaMaterials.hologramLineMaterial(color: style.tint, opacity: 1)
        )
        container.addChild(glow.entity)
        container.addChild(graticule.entity)
        container.addChild(core.entity)
        self.glow = glow
        self.graticule = graticule
        self.core = core

        buildPedestal(in: container, context: context)
        refresh(on: root, context: context)
    }

    func refresh(on root: DioramaEntity, context: DioramaEffectContext) {
        guard let terrain = root.terrain, let surface = terrain.surfaceBuffers else { return }
        guard let core, let glow else { return }

        let extent = max(context.boundary.extent.x, context.boundary.extent.y)
        let lineWidth = style.lineWidth * extent
        guard lineWidth > 0 else {
            core.clear()
            glow.clear()
            graticule?.clear()
            return
        }

        // Contours lie on the surface and the graticule drapes over it, so both are lifted off it by
        // the same amount to keep them out of the depth fight with the terrain they trace.
        let lift = extent * 0.0008
        let contours = contourSegments(for: surface, context: context)

        coreMesh.removeAll()
        glowMesh.removeAll()
        HologramGeometry.addRibbons(contours, width: lineWidth, yOffset: lift, into: &coreMesh)
        HologramGeometry.addRibbons(
            contours,
            width: lineWidth * style.glowWidth,
            yOffset: lift * 0.5,
            into: &glowMesh
        )
        core.update(with: coreMesh)
        glow.update(with: glowMesh)

        // Below the contours in the draw order and beneath them in the scene, so where the two cross
        // it is the contour that survives.
        updateGraticuleLines(for: surface, context: context)
        graticuleMesh.removeAll()
        HologramGeometry.addRibbons(
            graticuleLines,
            width: lineWidth * Self.graticuleWidthFactor,
            yOffset: lift * 0.25,
            into: &graticuleMesh
        )
        graticule?.update(with: graticuleMesh)
    }

    func reapply(to root: DioramaEntity, context: DioramaEffectContext) {
        guard container != nil else { return }
        // Forget what was saved before re-painting, so what the effect hands back on revert is the
        // imagery the chunk has now rather than the window it was showing when the effect went on.
        savedMaterials.removeAll()
        restyleBody(of: root)
        refresh(on: root, context: context)
    }

    func revert(from root: DioramaEntity) {
        container?.removeFromParent()
        container = nil
        core = nil
        glow = nil
        graticule = nil
        plate = nil
        rings = nil
        beam = nil

        for entity in hiddenEntities {
            entity.isEnabled = true
        }
        hiddenEntities.removeAll()
        graticuleLines.removeAll()

        restore(root.terrain?.surface)
        restore(root.terrain?.walls)
        restore(root.terrain?.bottom)
        for model in root.base?.children.compactMap({ $0 as? ModelEntity }) ?? [] {
            restore(model)
        }
        restore(root.base as? ModelEntity)
        savedMaterials.removeAll()
    }

    // MARK: - Lines

    /// Every line the hologram draws, as isolines of one axis or another.
    ///
    /// The graticule is genuinely the same operation as the contours — a set of levels traced across
    /// the same triangles, just measured along a horizontal axis instead of the vertical one — which
    /// is why it costs a second pass over the surface rather than a second implementation.
    private func contourSegments(
        for surface: TerrainSolidGenerator.Buffers,
        context: DioramaEffectContext
    ) -> [ContourExtractor.Segment] {
        var lower = Float.greatestFiniteMagnitude
        var upper = -Float.greatestFiniteMagnitude
        for position in surface.positions {
            lower = min(lower, position.y)
            upper = max(upper, position.y)
        }
        guard upper > lower else { return [] }

        return ContourExtractor.isolines(
            positions: surface.positions,
            indices: surface.indices,
            axis: .y,
            levels: elevationLevels(lower: lower, upper: upper, context: context)
        )
    }

    /// The straight ruling, draped over the relief.
    ///
    /// Levels are placed against the *boundary's* extent rather than the surface's, so the ruling is
    /// a property of the chunk rather than of whatever ground is under it — otherwise every pan step
    /// would re-space it and the whole grid would crawl.
    ///
    /// Re-traced from scratch on every step, which looks wasteful and measurably is not. A pan moves
    /// no vertex horizontally, so these crossings are provably invariant and caching them is
    /// available — it was built, measured against a re-trace back to back, and came out at 6.11 ms
    /// against 6.20 ms per step, inside the 0.5 ms this host drifts between identical runs. The
    /// trace is simply not where the time goes once it stops allocating per level.
    private func updateGraticuleLines(
        for surface: TerrainSolidGenerator.Buffers,
        context: DioramaEffectContext
    ) {
        guard style.graticuleDivisions > 0 else {
            graticuleLines.removeAll(keepingCapacity: true)
            return
        }
        let origin = context.boundary.minCorner
        let extent = context.boundary.extent

        graticuleLines = ContourExtractor.isolines(
            positions: surface.positions,
            indices: surface.indices,
            axis: .x,
            levels: .dividing(origin.x, origin.x + extent.x, into: style.graticuleDivisions)
        )
        graticuleLines += ContourExtractor.isolines(
            positions: surface.positions,
            indices: surface.indices,
            axis: .z,
            levels: .dividing(origin.y, origin.y + extent.y, into: style.graticuleDivisions)
        )
    }

    private func elevationLevels(
        lower: Float,
        upper: Float,
        context: DioramaEffectContext
    ) -> ContourExtractor.LevelSet {
        switch style.contours {
        case .automatic(let count):
            return .dividing(lower, upper, into: count)

        case .elevationMeters(let spacing):
            let spacing = Float(spacing)
            guard spacing > 0, context.elevationScale > 0 else {
                return ContourExtractor.LevelSet(first: 0, step: 0, count: 0)
            }
            // Levels land on multiples of the spacing in *real* elevation, the way a printed
            // topographic map is drawn — which is not the same as multiples of it above the chunk's
            // own floor, since Y = 0 is wherever the region happens to bottom out.
            let step = spacing * context.elevationScale
            let baseline = context.baselineElevation * context.elevationScale
            return .spaced(step, from: lower + baseline, to: upper + baseline)
                .shifted(by: -baseline)
        }
    }

    // MARK: - Pedestal

    /// Builds the plate the projection stands on, and the column of light between the two.
    ///
    /// Built once at `apply` rather than on every refresh, because none of it moves: the outline is
    /// fixed in diorama space and the plate's height is measured off that outline, so a pan slides
    /// the ground beneath a pedestal that stays exactly where it is. That is the same reason the
    /// graticule's *spacing* is taken from the boundary — a pedestal that drifted with the terrain
    /// would read as the projector sliding out from under its own projection.
    private func buildPedestal(in container: Entity, context: DioramaEffectContext) {
        guard let pedestal = style.pedestal else { return }

        let extent = max(context.boundary.extent.x, context.boundary.extent.y)
        // Y = 0 is the region's lowest ground, so the chunk's underside is the plane the drop hangs
        // from — not the terrain currently on screen, which a pan changes.
        let plateY = -pedestal.drop * extent
        let outline = HologramGeometry.scaled(context.boundary.vertices, by: Self.plateScale)

        if pedestal.plateOpacity > 0 {
            var material = DioramaMaterials.hologramBodyMaterial(
                color: style.surfaceColor,
                opacity: pedestal.plateOpacity
            )
            // Seen from below as readily as from above once the chunk can be orbited under.
            material.faceCulling = .none

            let plate = HologramLayer(name: "HologramPlate", material: material)
            container.addChild(plate.entity)
            var mesh = HologramMesh()
            HologramGeometry.addPlate(outline, y: plateY, into: &mesh)
            plate.update(with: mesh)
            self.plate = plate
        }

        if pedestal.rings > 0, style.lineWidth > 0 {
            let rings = HologramLayer(
                name: "HologramPedestalRings",
                material: DioramaMaterials.hologramLineMaterial(color: style.tint, opacity: 1)
            )
            container.addChild(rings.entity)

            var segments: [ContourExtractor.Segment] = []
            for index in 0..<pedestal.rings {
                let inset = Self.innermostRing * Float(index) / Float(pedestal.rings)
                segments += HologramGeometry.loop(
                    HologramGeometry.scaled(outline, by: 1 - inset),
                    y: plateY
                )
            }

            var mesh = HologramMesh()
            HologramGeometry.addRibbons(
                segments,
                width: style.lineWidth * extent,
                // Clear of the plate by the same margin the contours clear the terrain.
                yOffset: extent * 0.0008,
                into: &mesh
            )
            rings.update(with: mesh)
            self.rings = rings
        }

        if pedestal.beamOpacity > 0 {
            let beam = HologramLayer(
                name: "HologramBeam",
                material: DioramaMaterials.hologramLineMaterial(
                    color: style.tint,
                    opacity: pedestal.beamOpacity
                )
            )
            container.addChild(beam.entity)
            var mesh = HologramMesh()
            // Rising from the chunk's own footprint rather than the plate's rim, so the column ends
            // flush with the ground it is projecting instead of flaring past its edge.
            HologramGeometry.addBeam(context.boundary.vertices, from: plateY, to: 0, into: &mesh)
            beam.update(with: mesh)
            self.beam = beam
        }
    }

    // MARK: - Body

    /// Repaints the solid the lines are drawn over, saving what it replaces.
    private func restyleBody(of root: DioramaEntity) {
        let body = DioramaMaterials.hologramBodyMaterial(
            color: style.surfaceColor,
            opacity: style.surfaceOpacity
        )

        if !style.showsImagery {
            replace(root.terrain?.surface, with: body)
        }

        // The earth is taken away rather than painted, so the ground reads as hanging in the air.
        // Hiding it costs nothing to undo — `revert` re-enables what it switched off — and unlike a
        // fully transparent material it also takes the geometry out of the transparency sort, where
        // it would otherwise keep arguing with the surface over which is in front.
        if style.earthOpacity <= 0 {
            hide(root.terrain?.walls)
            hide(root.terrain?.bottom)
            hide(root.base)
        } else {
            let earth = DioramaMaterials.hologramBodyMaterial(
                color: style.surfaceColor,
                opacity: style.earthOpacity
            )
            replace(root.terrain?.walls, with: earth)
            replace(root.terrain?.bottom, with: earth)

            // The base is a plinth built elsewhere, so it may be one model or a container of them.
            if let base = root.base {
                replace(base as? ModelEntity, with: earth)
                for model in base.children.compactMap({ $0 as? ModelEntity }) {
                    replace(model, with: earth)
                }
            }
        }

        // Water reads as a mirror, which is the one thing a projection is not.
        hide(root.waterPlane)
    }

    /// Switches an entity off, remembering it so `revert` can switch it back on.
    private func hide(_ entity: Entity?) {
        guard let entity, entity.isEnabled else { return }
        entity.isEnabled = false
        hiddenEntities.append(entity)
    }

    private func replace(_ model: ModelEntity?, with material: any RealityKit.Material) {
        guard let model, var component = model.model else { return }
        let key = ObjectIdentifier(model)
        if savedMaterials[key] == nil {
            savedMaterials[key] = component.materials
        }
        component.materials = Array(repeating: material, count: max(1, component.materials.count))
        model.model = component
    }

    private func restore(_ model: ModelEntity?) {
        guard let model, let materials = savedMaterials[ObjectIdentifier(model)] else { return }
        model.model?.materials = materials
    }
}

// MARK: - Layers

/// One drawable piece of an effect, backed by a buffer it can be rewritten into.
///
/// The line set changes on every pan step — different heights mean different crossings, and the
/// triangle count changes with them — which is the shape `Tiles3DMeshBuffer` exists for. Compiling a
/// `MeshResource` per step instead is the cost the raster path measured at 12 ms against 0.14 ms for
/// a buffer write.
@MainActor
private final class HologramLayer {
    let entity = ModelEntity()
    private let material: any RealityKit.Material
    private var buffer: Tiles3DMeshBuffer?

    init(name: String, material: any RealityKit.Material) {
        self.material = material
        entity.name = name
    }

    func clear() {
        entity.isEnabled = false
    }

    func update(with mesh: HologramMesh) {
        guard !mesh.isEmpty else {
            clear()
            return
        }

        do {
            let buffer = try self.buffer ?? Tiles3DMeshBuffer(
                vertexCapacity: mesh.vertices.count,
                indexCapacity: mesh.indices.count
            )
            let fresh = self.buffer == nil
            self.buffer = buffer

            let outcome = try buffer.write(
                vertices: mesh.vertices,
                indices: mesh.indices,
                bounds: mesh.bounds
            )
            switch outcome {
            case .empty:
                clear()
                return
            case .regrown:
                entity.model = ModelComponent(mesh: buffer.resource, materials: [material])
            case .rewritten:
                if fresh || entity.model == nil {
                    entity.model = ModelComponent(mesh: buffer.resource, materials: [material])
                }
            }
            entity.isEnabled = true
        } catch {
            HologramLayer.logger.error("Could not write hologram geometry: \(error)")
            clear()
        }
    }

    private static let logger = Logger(subsystem: "com.maquette", category: "HologramEffect")
}

extension ContourExtractor.LevelSet {
    /// The same levels measured from a different origin.
    func shifted(by delta: Float) -> ContourExtractor.LevelSet {
        ContourExtractor.LevelSet(first: first + delta, step: step, count: count)
    }
}
