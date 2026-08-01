import CoreGraphics
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
    /// The composited satellite mosaic currently under the chunk, when there is one.
    ///
    /// The image rather than the material, because an effect that wants to restyle the imagery has to
    /// *read* it, and a `TextureResource` on the surface's material cannot be read back. It changes
    /// when a roll lands, which is the case `reapply` exists for.
    let imagery: CGImage?
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

    /// The globe's world mosaic, restyled the way this pass restyles the chunk's imagery.
    ///
    /// The handoff dissolves the chunk into the globe, and a styled chunk fading into a
    /// photographic world breaks the treatment at exactly the moment everything else is moving —
    /// an inked chunk should depart from an inked world. Only the *imagery* crosses over: the
    /// geometry half of an effect (crease lines, terrace steps, contour rings) reads the chunk's
    /// height field, and a sphere has none.
    ///
    /// Returning `nil` keeps the photographic mosaic, which is what the default does for a pass
    /// whose look has no image-level statement.
    func globeImagery(from world: CGImage) -> CGImage?

    /// How solid the restyled globe is drawn, in `0...1`. `1` — the default — is opaque.
    ///
    /// The one consumer is the hologram: its chunk reads as projected light because everything in
    /// it is translucent, and an opaque restyled sphere beside that reads as a painted marble.
    var globeOpacity: Float { get }
}

extension DioramaEffectPass {
    func globeImagery(from world: CGImage) -> CGImage? { nil }
    var globeOpacity: Float { 1 }
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
        case .ink(let style):
            return InkEffectPass(style: style)
        case .terraced(let style):
            return TerraceEffectPass(style: style)
        }
    }
}

// MARK: - Body

/// What an effect displaced when it repainted the diorama, so it can put it back.
///
/// `revert` has to be exact — an effect that could only be added would make `.none` mean "reload the
/// diorama" — and "exact" is easier to hold as a record of what was actually touched than as a list
/// of entities each pass remembers to walk. So this tracks the models it repainted rather than being
/// told about them again on the way out.
@MainActor
struct EffectBody {
    private var saved: [(model: ModelEntity, materials: [any RealityKit.Material])] = []
    private var repainted: Set<ObjectIdentifier> = []
    private var hidden: [Entity] = []

    /// Switches an entity off, remembering it.
    ///
    /// Hiding rather than painting transparent, where an effect wants something gone: it costs
    /// nothing to undo, and it takes the geometry out of the transparency sort, where it would
    /// otherwise keep arguing with the surface over which is in front.
    mutating func hide(_ entity: Entity?) {
        guard let entity, entity.isEnabled else { return }
        entity.isEnabled = false
        hidden.append(entity)
    }

    /// Repaints a model, saving its materials the first time.
    mutating func replace(_ model: ModelEntity?, with material: any RealityKit.Material) {
        guard let model, var component = model.model else { return }
        if repainted.insert(ObjectIdentifier(model)).inserted {
            saved.append((model, component.materials))
        }
        component.materials = Array(repeating: material, count: max(1, component.materials.count))
        model.model = component
    }

    /// Repaints the chunk's earth mass — its cut walls, its bottom face, and any plinth.
    ///
    /// The plinth is built elsewhere and may be one model or a container of them, which is the only
    /// reason this is worth a method rather than three calls.
    mutating func replaceEarth(of root: DioramaEntity, with material: any RealityKit.Material) {
        replace(root.terrain?.walls, with: material)
        replace(root.terrain?.bottom, with: material)
        if let base = root.base {
            replace(base as? ModelEntity, with: material)
            for model in base.children.compactMap({ $0 as? ModelEntity }) {
                replace(model, with: material)
            }
        }
    }

    /// Hides the chunk's earth mass.
    mutating func hideEarth(of root: DioramaEntity) {
        hide(root.terrain?.walls)
        hide(root.terrain?.bottom)
        hide(root.base)
    }

    /// Drops the saved materials without putting them back.
    ///
    /// For `reapply`, where the scene replaced its own materials underneath the effect: what the
    /// effect must hand back on the way out is the imagery the chunk has *now*, not the window it
    /// was showing when the effect went on.
    mutating func forgetMaterials() {
        saved.removeAll()
        repainted.removeAll()
    }

    /// Puts everything back and empties the record.
    mutating func restore() {
        for entry in saved {
            entry.model.model?.materials = entry.materials
        }
        saved.removeAll()
        repainted.removeAll()

        for entity in hidden {
            entity.isEnabled = true
        }
        hidden.removeAll()
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
    private static let logger = Logger(maquette: "HologramEffectPass")

    private let style: HologramStyle

    /// What the effect displaced, so `revert` can put the original diorama back.
    private var body = EffectBody()

    private var container: Entity?
    private var glow: EffectLayer?
    private var core: EffectLayer?
    private var graticule: EffectLayer?
    private var plate: EffectLayer?
    private var rings: EffectLayer?
    private var beam: EffectLayer?

    /// Reused between refreshes so a pan step does not reallocate the whole line set.
    private var glowMesh = IndexedMesh()
    private var coreMesh = IndexedMesh()
    private var graticuleMesh = IndexedMesh()

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

    /// The world as a projection: its own light, remapped into the hologram's tint.
    ///
    /// The chunk's treatment is line geometry a sphere cannot have, so the globe carries the
    /// *palette* half of the look — luma in, tint out, over near-black, which is what a projected
    /// earth reads as. The floor keeps the oceans present rather than dissolving the sphere's
    /// silhouette into the room, and the luma is lifted through a square root because satellite
    /// imagery lives in the midtones: mapped linearly the sphere came out as a dark marble, which
    /// beside a chunk made of glowing lines reads as a different effect entirely. The translucency
    /// (``globeOpacity``) is the other half of that fix — everything in the hologram is projected
    /// light, and light is not opaque.
    func globeImagery(from world: CGImage) -> CGImage? {
        try? Self.tintedMonochrome(world, tint: StrataTexture.rgbComponents(of: style.tint))
    }

    var globeOpacity: Float { 0.75 }

    /// Remaps an image's luma into a single tint over black.
    private static func tintedMonochrome(
        _ image: CGImage,
        tint: (Float, Float, Float)
    ) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw DioramaError.meshGenerationFailed(reason: "Cannot tint an empty image")
        }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        // Redrawn into a known layout rather than read through `dataProvider`, for the reason
        // `InkImagery.posterize` does: the source's component order is the decoder's business.
        let result: CGImage? = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let floor: Float = 0.14
            for row in 0..<height {
                var offset = row * bytesPerRow
                for _ in 0..<width {
                    let r = Float(raw[offset])
                    let g = Float(raw[offset + 1])
                    let b = Float(raw[offset + 2])
                    let luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255
                    let level = floor + (1 - floor) * luma.squareRoot()
                    raw[offset] = UInt8(min(level * tint.0 * 255, 255))
                    raw[offset + 1] = UInt8(min(level * tint.1 * 255, 255))
                    raw[offset + 2] = UInt8(min(level * tint.2 * 255, 255))
                    offset += 4
                }
            }
            return context.makeImage()
        }

        guard let result else {
            throw DioramaError.meshGenerationFailed(reason: "Failed to create tinting context")
        }
        return result
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
        let glow = EffectLayer(
            name: "HologramGlow",
            material: DioramaMaterials.hologramLineMaterial(
                color: style.tint,
                opacity: style.glowOpacity
            )
        )
        let graticule = EffectLayer(
            name: "HologramGraticule",
            material: DioramaMaterials.hologramLineMaterial(
                color: style.tint,
                opacity: Self.graticuleOpacity
            )
        )
        let core = EffectLayer(
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
        body.forgetMaterials()
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

        graticuleLines.removeAll()
        body.restore()
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
            levels: elevationLevels(
                lower: lower,
                upper: upper,
                context: context,
                drawnWidth: drawnLineWidth(context: context)
            )
        )
    }

    /// The width of a contour's bright core on the ground.
    ///
    /// The core, not the glow: the halo is a faint wash two lines can share without either
    /// becoming illegible, and measuring the spacing floor against it thinned the *resting*
    /// chunk's ladder — the fix for the zoomed-out scribble must not restyle the chunk at rest.
    private func drawnLineWidth(context: DioramaEffectContext) -> Float {
        let extent = max(context.boundary.extent.x, context.boundary.extent.y)
        return style.lineWidth * extent
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
        context: DioramaEffectContext,
        drawnWidth: Float
    ) -> ContourExtractor.LevelSet {
        // Levels are never packed closer than a few line-widths apart. A ground zoom divides the
        // elevation scale, so the relief under the outline compresses toward flat while the drawn
        // line keeps its width — and 22 isolines through near-flat noisy ground are space-filling
        // squiggles buried in the surface they trace, which on screen is a solid scribble tearing
        // against the body. Ink degrades on its own there (flatter ground passes fewer creases);
        // contours have to be told. Thinning the ladder instead of the lines keeps every contour
        // that *is* drawn legible, and a chunk zoomed out to a continent simply stops carrying
        // contours at all — the reading a printed map at that scale would make too. Two core
        // widths, calibrated so the default ladder is untouched at ground scale 1 on the demo's
        // own presets and runs out around an order of magnitude of zoom later.
        let minimumSpacing = drawnWidth * 2

        switch style.contours {
        case .automatic(let count):
            let relief = upper - lower
            var count = count
            if minimumSpacing > 0 {
                count = min(count, Int(relief / minimumSpacing))
            }
            guard count > 0 else { return ContourExtractor.LevelSet(first: 0, step: 0, count: 0) }
            return .dividing(lower, upper, into: count)

        case .elevationMeters(let spacing):
            var spacing = Float(spacing)
            guard spacing > 0, context.elevationScale > 0 else {
                return ContourExtractor.LevelSet(first: 0, step: 0, count: 0)
            }
            // Levels land on multiples of the spacing in *real* elevation, the way a printed
            // topographic map is drawn — which is not the same as multiples of it above the chunk's
            // own floor, since Y = 0 is wherever the region happens to bottom out.
            var step = spacing * context.elevationScale
            if step < minimumSpacing {
                // Decimated by a whole factor so the survivors stay on printed-map multiples.
                let factor = (minimumSpacing / step).rounded(.up)
                spacing *= factor
                step *= factor
            }
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
            // Tinted rather than painted in `surfaceColor`, which is what the rest of the chunk's
            // body uses. That colour is near-black and the backdrop behind the effect is the same
            // colour, so the plate drew nothing at any opacity: sampled off a screenshot it came
            // back (3,13,19) against a background of (3,14,22), and `plateOpacity` was a knob with
            // no visible range at all.
            var material = DioramaMaterials.hologramBodyMaterial(
                color: style.tint,
                opacity: pedestal.plateOpacity
            )
            // Seen from below as readily as from above once the chunk can be orbited under.
            material.faceCulling = .none

            let plate = EffectLayer(name: "HologramPlate", material: material)
            container.addChild(plate.entity)
            var mesh = IndexedMesh()
            HologramGeometry.addPlate(outline, y: plateY, into: &mesh)
            plate.update(with: mesh)
            self.plate = plate
        }

        if pedestal.rings > 0, style.lineWidth > 0 {
            let rings = EffectLayer(
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

            var mesh = IndexedMesh()
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
            var material = DioramaMaterials.hologramLineMaterial(
                color: style.tint,
                opacity: pedestal.beamOpacity
            )
            // The one place in this effect that culls. Everything else is a ribbon that has to
            // survive being seen edge-on from beneath, but the column is a closed prism, and drawn
            // with culling off a single ray crosses four of its surfaces — near wall and far wall,
            // each front and back. The stated opacity would then arrive on screen at roughly four
            // times its value, which is how a faint column turns into a solid drum. Culling leaves
            // one wall standing, so the number means what it says.
            material.faceCulling = .back

            let beam = EffectLayer(name: "HologramBeam", material: material)
            container.addChild(beam.entity)
            var mesh = IndexedMesh()
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
        let surface = DioramaMaterials.hologramBodyMaterial(
            color: style.surfaceColor,
            opacity: style.surfaceOpacity
        )

        if !style.showsImagery {
            body.replace(root.terrain?.surface, with: surface)
        }

        // The earth is taken away rather than painted, so the ground reads as hanging in the air.
        if style.earthOpacity <= 0 {
            body.hideEarth(of: root)
        } else {
            body.replaceEarth(
                of: root,
                with: DioramaMaterials.hologramBodyMaterial(
                    color: style.surfaceColor,
                    opacity: style.earthOpacity
                )
            )
        }

        // Water reads as a mirror, which is the one thing a projection is not.
        body.hide(root.waterPlane)
    }
}

// MARK: - Layers

/// One drawable piece of an effect, backed by a buffer it can be rewritten into.
///
/// The line set changes on every pan step — different heights mean different crossings, and the
/// triangle count changes with them — which is the shape `Tiles3DMeshBuffer` exists for. Compiling a
/// `MeshResource` per step instead is the cost the raster path measured at 12 ms against 0.14 ms for
/// a buffer write.
///
/// Shared by every pass rather than owned by one, because none of it is about contours or about ink:
/// a layer is a mesh, a material, and the ability to be rewritten cheaply, which is what each of an
/// effect's drawn pieces needs.
@MainActor
final class EffectLayer {
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

    func update(with mesh: IndexedMesh) {
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
            EffectLayer.logger.error("Could not write effect geometry: \(error)")
            clear()
        }
    }

    private static let logger = Logger(maquette: "DioramaEffectPass")
}

extension ContourExtractor.LevelSet {
    /// The same levels measured from a different origin.
    func shifted(by delta: Float) -> ContourExtractor.LevelSet {
        ContourExtractor.LevelSet(first: first + delta, step: step, count: count)
    }
}
