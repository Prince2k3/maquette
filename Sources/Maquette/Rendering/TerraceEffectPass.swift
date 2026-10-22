import CoreGraphics
import Foundation
import os
import RealityKit
import SwiftUI
import simd

/// Cuts the chunk into stacked flat steps and paints it from a colour ramp by height, the way a
/// contour model is built up out of sheets of card.
///
/// Where the ink effect draws lines *over* the chunk, this one replaces the chunk's surface with a
/// second copy of it — the same triangles with their heights quantized — and hides the original. That
/// is a bigger intervention than a line layer, and it is what makes the step faces real geometry that
/// catches the light rather than a pattern painted on a smooth slope.
///
/// The whole thing is one mesh with one material, plateaus and risers alike; which of the two a
/// triangle is decides only which row of the palette strip it reads. See ``TerraceGeometry`` for why
/// quantizing per vertex gives exactly-flat plateaus and exactly-one-cell risers without a single
/// normal being averaged, and ``TerracePalette`` for how two rows stand in for two materials.
///
/// What it is painted comes from the place rather than from a preset: ``TerraceImagery`` averages the
/// mosaic at each band's own height, so the same effect over the same ladder reads as ochre over
/// canyon country and green over a forested valley. Measured once, at `apply`, and then held.
///
/// The walls come along, and are not decoration. Quantization rounds heights down, so a wall left as
/// the generator built it stands up to a full step proud of the surface it is supposed to meet, and
/// the chunk gets a ragged lip of strata all the way around its rim.
@MainActor
final class TerraceEffectPass: DioramaEffectPass {
    private static let logger = Logger(maquette: "TerraceEffectPass")

    private let style: TerraceStyle

    private var body = EffectBody()
    private var container: Entity?
    private var surface: EffectLayer?
    private var walls: EffectLayer?
    private var bottom: EffectLayer?

    /// Reused between refreshes so a pan step does not reallocate the whole chunk.
    private var surfaceMesh = IndexedMesh()
    private var wallMesh = IndexedMesh()
    private var bottomMesh = IndexedMesh()

    /// The ladder, measured at `apply` and then held.
    ///
    /// This is the one piece of state that must not be re-derived per step. A pan slides new ground
    /// under the outline, so levels taken from whatever is currently on screen would move every step
    /// in the model at once and the whole chunk would jump on every frame of a drag — the same
    /// failure the wall texture's vertical reference, the elevation baseline, and `InkImagery`'s tonal
    /// range are all frozen to avoid.
    private var bands: TerraceBands?

    private var baseDepth: Float = 0
    private var wallHeight: Float = 0

    init(style: TerraceStyle) {
        self.style = style
    }

    /// The world's mosaic in flat tonal bands, the nearest image-level statement of the terrace.
    ///
    /// The chunk's paint is measured per *elevation* band, and a sphere has no elevation to band
    /// by — so the globe takes the same flat-fill look keyed by tone instead, one band per step of
    /// the ladder, through the same machinery the ink effect flattens with. The style's own
    /// saturation push rides along, so a muted terrace gets a muted world.
    func globeImagery(from world: CGImage) -> CGImage? {
        let levels: Int
        switch style.steps {
        case .automatic(let count):
            levels = max(count, 2)
        case .elevationMeters:
            levels = 8
        }
        return try? InkImagery.posterize(
            world,
            recipe: InkImagery.Recipe(patchSize: 24, levels: levels, saturation: style.saturation)
        ).image
    }

    func apply(to root: DioramaEntity, context: DioramaEffectContext) {
        guard let terrain = root.terrain, let buffers = terrain.surfaceBuffers else {
            Self.logger.info(
                """
                The terraced effect needs a raster terrain chunk and this diorama has none; \
                leaving it as it is
                """
            )
            return
        }

        guard let bands = makeBands(for: buffers, context: context) else {
            Self.logger.info("This chunk has no relief to terrace; leaving it as it is")
            return
        }
        self.bands = bands
        baseDepth = -terrain.surfaceFloorY
        wallHeight = terrain.wallHeight

        let surfaceMaterial: any RealityKit.Material
        do {
            guard let image = paletteImage(for: bands, buffers: buffers, context: context) else {
                Self.logger.error("Could not render the terrace palette; leaving the chunk as it is")
                self.bands = nil
                return
            }
            surfaceMaterial = try DioramaMaterials.terraceSurfaceMaterial(
                from: image,
                roughness: style.roughness
            )
        } catch {
            Self.logger.error("Could not build the terrace material: \(error)")
            self.bands = nil
            return
        }

        // The wall keeps whatever the chunk's own style painted it unless the style asks otherwise,
        // because a stacked-card model *has* visible layers down its sides and the strata already are
        // that. Taken from the model rather than rebuilt, so the procedural texture is not rendered a
        // second time.
        let wallMaterial: any RealityKit.Material = style.blockColor.map {
            DioramaMaterials.litMaterial(color: $0, roughness: style.roughness)
        } ?? terrain.wallMaterials.first ?? DioramaMaterials.litMaterial(
            color: .init(white: 0.7),
            roughness: style.roughness
        )

        restyleBody(of: root)

        let container = Entity()
        container.name = "TerraceEffect"
        terrain.addChild(container)
        self.container = container

        let surface = EffectLayer(name: "TerraceSurface", material: surfaceMaterial)
        let walls = EffectLayer(name: "TerraceWalls", material: wallMaterial)
        container.addChild(surface.entity)
        container.addChild(walls.entity)
        self.surface = surface
        self.walls = walls
        if let material = terrain.bottom?.model?.materials.first {
            let bottom = EffectLayer(name: "TerraceBottom", material: material)
            container.addChild(bottom.entity)
            self.bottom = bottom
        }

        refresh(on: root, context: context)
    }

    func refresh(on root: DioramaEntity, context: DioramaEffectContext) {
        guard let bands, let surface, let walls, let terrain = root.terrain else { return }
        guard let buffers = terrain.surfaceBuffers else { return }

        TerraceGeometry.buildSurface(from: buffers, bands: bands, minimumY: -baseDepth, into: &surfaceMesh)
        surface.update(with: surfaceMesh)

        if let wallBuffers = terrain.wallBuffers {
            TerraceGeometry.buildWalls(
                from: wallBuffers,
                bands: bands,
                baseDepth: baseDepth,
                wallHeight: wallHeight,
                into: &wallMesh
            )
            walls.update(with: wallMesh)
        }
        if let bottom, let buffers = terrain.bottomBuffers, let surface = terrain.surfaceBuffers {
            TerraceGeometry.buildBottom(from: buffers, surface: surface,
                surfaceIndices: terrain.bottomSurfaceIndices, bands: bands,
                minimumY: -baseDepth, into: &bottomMesh)
            bottom.update(with: bottomMesh)
        }
    }

    func reapply(to root: DioramaEntity, context: DioramaEffectContext) {
        guard container != nil else { return }
        // The chunk repainted itself, which is what a roll landing looks like: the imagery is new and
        // the originals this effect saved are stale. The palette was measured off that imagery, and
        // is deliberately *not* measured again — a roll brings in a tile or two while the ground has
        // barely moved, and re-measuring would repaint every band in the model at once. Same
        // discipline as the ladder above and `InkImagery`'s tonal range. So the only work is to hide
        // the restored models again and rebuild.
        body.forgetMaterials()
        restyleBody(of: root)
        refresh(on: root, context: context)
    }

    func revert(from root: DioramaEntity) {
        container?.removeFromParent()
        container = nil
        surface = nil
        walls = nil
        bottom = nil
        bands = nil
        surfaceMesh.removeAll()
        wallMesh.removeAll()
        bottomMesh.removeAll()
        body.restore()
    }

    // MARK: - Body

    /// Takes away the smooth chunk the terraced copy stands in for, and paints what is left.
    private func restyleBody(of root: DioramaEntity) {
        // Hidden rather than painted: both copies occupy the same space, and leaving the smooth one
        // drawn would put it in a depth fight with the steps built from it.
        body.hide(root.terrain?.surface)
        body.hide(root.terrain?.walls)
        body.hide(root.terrain?.bottom)

        if let blockColor = style.blockColor {
            let material = DioramaMaterials.litMaterial(
                color: blockColor,
                roughness: style.roughness
            )
            body.replace(root.terrain?.bottom, with: material)
            if let base = root.base {
                body.replace(base as? ModelEntity, with: material)
                for model in base.children.compactMap({ $0 as? ModelEntity }) {
                    body.replace(model, with: material)
                }
            }
        }

        // Water is drawn as a mirror everywhere else in the library, and a mirror among flat painted
        // steps reads as a hole in the model rather than as a lake.
        if let waterColor = style.waterColor, let water = root.waterPlane as? ModelEntity {
            body.replace(
                water,
                with: DioramaMaterials.litMaterial(color: waterColor, roughness: 0.25)
            )
        }
    }

    // MARK: - Palette

    /// The strip the whole chunk is painted from, measured off the ground unless the style names a
    /// ramp.
    ///
    /// Built here, at `apply`, and then held for the life of the effect — see `reapply` for why it is
    /// never measured a second time.
    private func paletteImage(
        for bands: TerraceBands,
        buffers: TerrainSolidGenerator.Buffers,
        context: DioramaEffectContext
    ) -> CGImage? {
        if let colors = style.colors {
            return TerracePalette.makeImage(
                colors: colors,
                count: bands.count,
                riserShade: style.riserShade
            )
        }

        if let imagery = context.imagery,
           let measured = TerraceImagery.palette(
               from: imagery,
               positions: buffers.positions,
               textureCoordinates: buffers.uvs,
               bands: bands,
               recipe: .init(saturation: style.saturation, contrast: style.contrast)
           ) {
            return TerracePalette.makeImage(bands: measured, riserShade: style.riserShade)
        }

        // A chunk with no imagery under it — an elevation-only diorama — has no colours to take, so
        // it falls back to the warm earth a contour model is conventionally printed in.
        Self.logger.info("No imagery to take the terrace palette from; using the default ramp")
        return TerracePalette.makeImage(
            colors: Self.fallbackRamp,
            count: bands.count,
            riserShade: style.riserShade
        )
    }

    private static let fallbackRamp: [Color] = [
        Color(red: 0.38, green: 0.14, blue: 0.10),
        Color(red: 0.68, green: 0.26, blue: 0.13),
        Color(red: 0.87, green: 0.44, blue: 0.17),
        Color(red: 0.95, green: 0.63, blue: 0.29),
        Color(red: 0.98, green: 0.80, blue: 0.53),
        Color(red: 0.99, green: 0.93, blue: 0.80),
    ]

    // MARK: - Bands

    private func makeBands(
        for buffers: TerrainSolidGenerator.Buffers,
        context: DioramaEffectContext
    ) -> TerraceBands? {
        guard let relief = TerraceGeometry.relief(of: buffers.positions) else { return nil }

        switch style.steps {
        case .automatic(let count):
            return TerraceBands(dividing: relief.lower, relief.upper, into: count)

        case .elevationMeters(let spacing):
            return TerraceBands(
                everyMeters: Float(spacing),
                elevationScale: context.elevationScale,
                baselineElevation: context.baselineElevation,
                lower: relief.lower,
                upper: relief.upper
            )
        }
    }
}
