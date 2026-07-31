import Foundation
import SwiftUI

/// How far apart an effect's elevation bands sit — a hologram's contour lines, or the steps a
/// terraced chunk is cut into.
public enum ContourInterval: Sendable, Equatable {
    /// Divide the terrain's relief into this many bands.
    ///
    /// Keeps the line density readable whatever the region: a flat delta and an alpine face both
    /// come out with the same number of contours rather than one drawing thousands and the other none.
    case automatic(count: Int)

    /// A fixed spacing in real-world elevation meters, the way a printed topographic map is drawn.
    ///
    /// Regions with little relief may produce very few lines, or none at all.
    case elevationMeters(Double)
}

/// The plate a hologram is projected from.
///
/// A chunk with its earth removed reads as floating, which is the point — but floating from *nowhere*
/// reads as an object that has simply lost its bottom. The plate gives the projection a source: a
/// disc below the chunk, ringed with light, with a faint column of light standing between the two.
///
/// Every length here is a fraction of the chunk's largest horizontal extent, as everywhere else in
/// this style, rather than a multiple of how deep the chunk's earth was cut. That distinction is
/// load-bearing: a chunk styled with no earth at all — `ChunkBaseDepth.absolute(0)`, which the
/// Surface preset uses — would otherwise put its plate inside its own terrain.
public struct HologramPedestal: Sendable, Equatable {
    /// How far the plate sits below the chunk's lowest ground.
    public var drop: Float
    /// Opacity of the plate itself, in `0...1`.
    ///
    /// The plate is drawn in the style's tint, so this reads the same way `beamOpacity` does and
    /// wants the same small numbers — see that property for why a blend factor arrives on screen
    /// several times brighter than it looks here. Measured on this style's own backdrop, the
    /// default `0.02` sampled off the screen as an apparent `0.047`.
    ///
    /// That is deliberately dimmer than the column, which is the reverse of how the two numbers
    /// read in isolation: the plate is a filled disc wider than the chunk, so it covers far more of
    /// the frame than a band of light does, and the same blend factor on it reads as a solid object
    /// rather than as a glow.
    public var plateOpacity: Float
    /// How many rings of light are drawn on the plate, working inwards from its rim.
    public var rings: Int
    /// Opacity of the column of light between the plate and the chunk, in `0...1`. `0` draws none.
    ///
    /// Two things make this number read far brighter than it looks, which is why the default is so
    /// much smaller than the rest of the style's opacities.
    ///
    /// The column is a closed prism, so drawn the way the rest of the effect is drawn — culling off,
    /// both sides of every face — a single ray would cross four of its surfaces and land at roughly
    /// four times this value. That is the difference between a faint column and a solid drum, so the
    /// beam is the one piece of the effect that culls.
    ///
    /// And blending happens in linear space while the result is displayed in sRGB, so even one
    /// surface arrives brighter than its blend factor. Measured against this style's tint on its own
    /// backdrop, `0.12` sampled off the screen as an apparent `0.32`; the relationship is steep
    /// enough near zero that the visible range worth tuning in is roughly `0.02...0.05`.
    public var beamOpacity: Float

    /// Creates a pedestal.
    public init(
        drop: Float = 0.09,
        plateOpacity: Float = 0.02,
        rings: Int = 3,
        beamOpacity: Float = 0.03
    ) {
        self.drop = max(0, drop)
        self.plateOpacity = max(0, min(1, plateOpacity))
        self.rings = max(0, rings)
        self.beamOpacity = max(0, min(1, beamOpacity))
    }

    /// A plate a little wider than the chunk, three rings, and a faint column. The default.
    public static let standard = HologramPedestal()
}

/// The look of the `.hologram` effect.
///
/// Every length here is a fraction of the chunk's largest horizontal extent rather than an absolute
/// measurement, so a style reads the same on a tabletop diorama and a room-scale one.
public struct HologramStyle: Sendable, Equatable {
    /// Color of the contour lines and the graticule.
    public var tint: Color
    /// Color of the chunk's body beneath the lines.
    public var surfaceColor: Color
    /// Opacity of the chunk's body, in `0...1`.
    ///
    /// Low by default, so the contours on the far side of the chunk show through the ground in front
    /// of them — which is what makes the thing read as projected light rather than as a painted
    /// object. It is only low because `earthOpacity` is zero: RealityKit sorts transparent geometry
    /// per-object rather than per-triangle, and with cut walls in the scene a see-through surface
    /// spends the whole time arguing with them over which is in front. Raise `earthOpacity` and this
    /// should come back up with it.
    public var surfaceOpacity: Float
    /// Opacity of the chunk's earth mass — its cut walls, its bottom face, and any plinth — in
    /// `0...1`. `0`, the default, removes them.
    ///
    /// The chunk is a solid everywhere else in this library, and under every other treatment that is
    /// the point. A projection is the exception: a slab of earth beneath the lines reads as an object
    /// resting on something, and the effect is meant to read as an image of the ground hanging in
    /// the air with nothing holding it up. The strata are also the one part of the chunk that is
    /// invented rather than measured, so they are the first thing a data projection should drop.
    ///
    /// Raising this paints the earth in `surfaceColor` instead of removing it. Values in between
    /// are where RealityKit's per-object transparency sorting shows: the walls and the surface will
    /// visibly argue over which is in front.
    public var earthOpacity: Float
    /// Spacing of the elevation contours.
    public var contours: ContourInterval
    /// Width of a contour line's bright core, as a fraction of the chunk's largest extent.
    public var lineWidth: Float
    /// Width of the halo drawn behind each line, as a multiple of `lineWidth`.
    ///
    /// RealityKit exposes no post-process bloom that works on all four platforms, so the glow is a
    /// second, wider, fainter pass rather than a filter.
    public var glowWidth: Float
    /// Opacity of that halo, in `0...1`.
    public var glowOpacity: Float
    /// Number of graticule lines per horizontal axis, draped over the terrain. `0` draws none.
    public var graticuleDivisions: Int
    /// The plate the chunk is projected from, or `nil` to leave it hanging from nothing.
    public var pedestal: HologramPedestal?
    /// Whether to keep the satellite imagery beneath the effect instead of replacing it with
    /// `surfaceColor`.
    public var showsImagery: Bool

    /// Creates a hologram style.
    public init(
        tint: Color = Color(red: 0.25, green: 0.95, blue: 0.94),
        surfaceColor: Color = Color(red: 0.012, green: 0.055, blue: 0.085),
        surfaceOpacity: Float = 0.3,
        earthOpacity: Float = 0,
        contours: ContourInterval = .automatic(count: 22),
        lineWidth: Float = 0.0035,
        glowWidth: Float = 3.5,
        glowOpacity: Float = 0.18,
        graticuleDivisions: Int = 12,
        pedestal: HologramPedestal? = .standard,
        showsImagery: Bool = false
    ) {
        self.tint = tint
        self.surfaceColor = surfaceColor
        self.surfaceOpacity = max(0, min(1, surfaceOpacity))
        self.earthOpacity = max(0, min(1, earthOpacity))
        self.contours = contours
        self.lineWidth = max(0, lineWidth)
        self.glowWidth = max(1, glowWidth)
        self.glowOpacity = max(0, min(1, glowOpacity))
        self.graticuleDivisions = max(0, graticuleDivisions)
        self.pedestal = pedestal
        self.showsImagery = showsImagery
    }

    /// Cyan contours on a near-black body. The default.
    public static let standard = HologramStyle()

    /// A denser, colder read with a tighter contour interval.
    public static let survey = HologramStyle(
        tint: Color(red: 0.55, green: 0.85, blue: 1.0),
        contours: .automatic(count: 40),
        lineWidth: 0.0022,
        glowWidth: 2.5,
        glowOpacity: 0.12,
        graticuleDivisions: 20
    )

    /// Amber lines, in the register of an older display.
    public static let amber = HologramStyle(
        tint: Color(red: 1.0, green: 0.68, blue: 0.22),
        surfaceColor: Color(red: 0.06, green: 0.035, blue: 0.01),
        contours: .automatic(count: 18),
        graticuleDivisions: 8
    )
}

/// The look of the `.ink` effect.
///
/// A hand-drawn treatment: black outlines traced along every hard edge of the chunk, flat cel-shaded
/// colour between them, and the earth beneath reduced to a plain grey block. Lengths are fractions of
/// the chunk's largest horizontal extent, as in ``HologramStyle``, so the same style reads the same
/// on a tabletop diorama and a room-scale one.
///
/// One limit worth knowing before tuning ``lineWidth``: the lines are geometry, not a screen-space
/// post-process — RealityKit exposes none that works on all four platforms — so their width is in
/// diorama meters and they thicken as the chunk is zoomed into, rather than holding a constant weight
/// on screen the way a drawn line does.
public struct InkStyle: Sendable, Equatable {
    /// Color of every drawn line.
    public var lineColor: Color
    /// Width of a line, as a fraction of the chunk's largest extent.
    public var lineWidth: Float
    /// Color of the chunk's earth — its cut walls, its bottom face, and any plinth.
    ///
    /// One flat grey, replacing the strata. The bands are the one part of a chunk that is invented
    /// rather than measured, and the reference look draws the block as a plain solid rather than as
    /// geology.
    public var blockColor: Color
    /// The color a view sits the chunk against. Warm off-white by default, like paper.
    public var paperColor: Color
    /// How many bands of tone the satellite imagery is reduced to. Lower is flatter.
    public var colorLevels: Int
    /// Source pixels per flat patch of colour, along each axis.
    ///
    /// The single value that decides whether the ground reads as an illustration or as camouflage,
    /// and it wants to be much larger than it looks like it should: a mosaic runs to a couple of
    /// thousand pixels a side, so a patch of four is a fifth of a millimetre on the chunk and every
    /// bush in the imagery survives as its own flat speck.
    public var patchSize: Int
    /// How far each colour is pushed from its own grey, to make up for aerial haze.
    public var saturation: Float
    /// How sharply the surface must fold, in degrees, before the fold is worth inking as a crease.
    ///
    /// Wants to be shallow — much shallower than it reads — because it is a *floor* on what may be
    /// drawn rather than a description of what will be. Set steep enough to admit only cliffs and
    /// ridge lines, it also refuses gentle ground everything: a plateau beside a mountain range
    /// offers no candidate at all, so it is inked bare and reads as a flat slab next to a drawn one,
    /// which is the opposite of what raising the threshold was meant to achieve. Shallow enough that
    /// ordinary undulation qualifies, every part of the chunk has something to draw and
    /// ``creaseDensity`` decides how much of it survives.
    public var creaseAngle: Float
    /// The largest share of the surface's interior edges that may be inked as creases.
    ///
    /// The angle above decides *whether* a fold is worth a line; this decides *how many* lines the
    /// drawing gets, and the two answer different questions. Left to the angle alone the density is
    /// a property of the ground rather than of the drawing, and panning across a chunk shows both
    /// ends of that: rugged terrain inks until it is solid black, flat terrain a few hundred metres
    /// away is left almost bare, and the cost of a pan step grows with whatever slid into view. The
    /// share is spread evenly over the chunk and each patch keeps its own sharpest folds, so a
    /// plateau still gets its drainages while a mountain range stops short of a scribble.
    public var creaseDensity: Float
    /// How sharply the outline must turn, in degrees, before its vertex is inked as a vertical corner.
    ///
    /// A square outline has four corners at 90°, and a circular one is drawn as a hundred-odd short
    /// segments turning about 3° each — so this is what stops a circular chunk being inked into a
    /// solid drum.
    public var cornerAngle: Float
    /// Whether to keep the satellite imagery, flattened, beneath the lines.
    ///
    /// `false` paints the surface a single flat colour instead, which is closer to the drawn
    /// reference and drops the one thing that makes the chunk the place it is.
    public var showsImagery: Bool
    /// The flat colour used for the surface when `showsImagery` is `false`.
    public var surfaceColor: Color
    /// The flat colour the sea-level plane is painted, when the chunk has one.
    ///
    /// Water is the one surface a flat treatment cannot leave alone: it is drawn as a mirror
    /// everywhere else in the library, and a mirror among cel-shaded fills reads as a hole in the
    /// picture rather than as the sea.
    public var waterColor: Color

    /// Creates an ink style.
    public init(
        lineColor: Color = Color(red: 0.07, green: 0.06, blue: 0.06),
        lineWidth: Float = 0.0032,
        blockColor: Color = Color(white: 0.74),
        paperColor: Color = Color(red: 0.93, green: 0.91, blue: 0.87),
        colorLevels: Int = 5,
        patchSize: Int = 24,
        saturation: Float = 1.8,
        creaseAngle: Float = 14,
        creaseDensity: Float = 0.06,
        cornerAngle: Float = 25,
        showsImagery: Bool = true,
        surfaceColor: Color = Color(red: 0.76, green: 0.79, blue: 0.66),
        waterColor: Color = Color(red: 0.36, green: 0.72, blue: 0.71)
    ) {
        self.lineColor = lineColor
        self.lineWidth = max(0, lineWidth)
        self.blockColor = blockColor
        self.paperColor = paperColor
        self.colorLevels = max(2, colorLevels)
        self.patchSize = max(1, patchSize)
        self.saturation = max(0, saturation)
        self.creaseAngle = max(1, min(179, creaseAngle))
        self.creaseDensity = max(0, min(1, creaseDensity))
        self.cornerAngle = max(1, min(179, cornerAngle))
        self.showsImagery = showsImagery
        self.surfaceColor = surfaceColor
        self.waterColor = waterColor
    }

    /// Black lines over flattened imagery on a grey block. The default.
    public static let standard = InkStyle()

    /// No photography at all — flat colour between the lines, as the reference is drawn.
    public static let flat = InkStyle(colorLevels: 3, showsImagery: false)

    /// Heavier lines and fewer colours, closer to a printed comic panel.
    public static let bold = InkStyle(
        lineWidth: 0.005,
        colorLevels: 4,
        patchSize: 48,
        saturation: 2.2,
        creaseAngle: 12
    )
}

/// The look of the `.terraced` effect.
///
/// A model-maker's treatment: the terrain cut into stacked flat steps, the way a contour model is
/// built up out of sheets of card, and painted from a colour ramp by height rather than from
/// photography. What makes it read as a made object rather than as a low-resolution render is that
/// the plateaus are exactly flat and the steps between them are vertical — see `TerraceGeometry`
/// for why quantizing per vertex delivers both for free.
public struct TerraceStyle: Sendable, Equatable {
    /// How the terrain's height is divided into steps.
    ///
    /// `.automatic(count:)` divides the chunk's own relief, so a flat delta and an alpine face both
    /// come out with the same number of steps. `.elevationMeters` puts the steps on multiples of a
    /// real elevation, the way a contour model is cut from a map.
    ///
    /// Either way the ladder is measured once, when the effect is switched on, and then held. Panning
    /// slides new ground under the outline, and re-measuring against whatever is currently on screen
    /// would re-cut every step in the model at once — the whole thing would jump every frame of a
    /// drag.
    public var steps: ContourInterval
    /// The colour ramp, lowest ground first, or `nil` to take the colours off the ground itself.
    ///
    /// `nil` by default, and that default is the effect: each band is painted the average colour of
    /// the imagery at that height, so canyon country comes out in ochres and a forested valley in
    /// greens without anyone choosing. A ramp given here overrides that measurement and is
    /// interpolated across however many steps the ladder produces, so its length is a description of
    /// the palette rather than of the terrain and the two need not agree.
    public var colors: [Color]?
    /// How far the measured colours are pushed away from what the camera recorded, in each of two
    /// directions.
    ///
    /// Ignored when ``colors`` names a ramp. Aerial imagery is hazy to begin with and averaging a
    /// whole band of it drags every band towards the same brown, so `saturation` scales a band's
    /// distance from its own grey and `contrast` its distance from the ladder's mean brightness.
    /// Both exaggerate differences the ground has; neither can invent one.
    public var saturation: Float
    /// See ``saturation``.
    public var contrast: Float
    /// What a band's colour is multiplied by on the vertical face of its step, in `0...1`.
    ///
    /// The material is lit, so a step face already darkens where it turns away from the light. This
    /// is what keeps the steps legible on the faces that do not — the ones turned towards it.
    public var riserShade: Float
    /// The colour of the chunk's earth — its cut walls, its bottom face, and any plinth — or `nil` to
    /// leave whatever `TerrainChunkStyle` painted them.
    ///
    /// `nil` by default, because a stacked-card model *has* visible layers down its sides and the
    /// chunk's strata already are that. A flat colour is the toy register instead, where the block
    /// beneath reads as one moulded piece.
    public var blockColor: Color?
    /// The flat colour the sea-level plane is painted, when the chunk has one, or `nil` to leave it.
    ///
    /// Water is the one surface a flat treatment cannot leave alone: it is drawn as a mirror
    /// everywhere else in the library, and a mirror among flat painted steps reads as a hole.
    public var waterColor: Color?
    /// The colour a view sits the chunk against.
    public var backgroundColor: Color
    /// How matte the painted surface is, in `0...1`. High reads as card or clay; low reads as plastic.
    public var roughness: Float

    /// Creates a terrace style.
    public init(
        steps: ContourInterval = .automatic(count: 16),
        colors: [Color]? = nil,
        saturation: Float = 1.6,
        contrast: Float = 1.5,
        riserShade: Float = 0.78,
        blockColor: Color? = nil,
        waterColor: Color? = Color(red: 0.35, green: 0.55, blue: 0.62),
        backgroundColor: Color = Color(red: 0.10, green: 0.08, blue: 0.09),
        roughness: Float = 0.95
    ) {
        self.steps = steps
        self.colors = colors.map { $0.isEmpty ? [Color(white: 0.7)] : $0 }
        self.saturation = max(0, saturation)
        self.contrast = max(0, contrast)
        self.riserShade = max(0, min(1, riserShade))
        self.blockColor = blockColor
        self.waterColor = waterColor
        self.backgroundColor = backgroundColor
        self.roughness = max(0, min(1, roughness))
    }

    /// The chunk's own colours, cut into steps. The default.
    public static let standard = TerraceStyle()

    /// Few, deep steps, the way a model cut from thick card comes out.
    public static let card = TerraceStyle(steps: .automatic(count: 8), riserShade: 0.7)
}

/// A visual treatment applied over a built diorama.
///
/// An effect is a restyle of the finished scene rather than a different way of building it, so
/// turning one on or off never refetches a tile and never rebuilds the chunk. It composes with
/// whatever `TerrainChunkStyle` produced: the chunk is still a solid with walls and a bottom, it is
/// just painted differently.
///
/// ```swift
/// DioramaView(configuration: config)
///     .dioramaEffect(.hologram)
/// ```
///
/// The set is closed. Adding an effect is a change to this library rather than something a caller
/// can do from outside, which keeps the entity tree free to change underneath.
public struct DioramaEffect: Sendable, Equatable {
    /// Which treatment to apply. Kept internal so the case list can grow without breaking callers
    /// who only ever name the static members.
    enum Kind: Sendable, Equatable {
        case none
        case hologram(HologramStyle)
        case ink(InkStyle)
        case terraced(TerraceStyle)
    }

    let kind: Kind

    /// No effect. The diorama renders as its configuration describes it.
    public static let none = DioramaEffect(kind: .none)

    /// A projected-terrain look: glowing elevation contours over a dark body.
    ///
    /// Only the raster terrain chunk carries it. Contours are isolines of the surface's own
    /// elevation, and a photorealistic 3D Tiles model is triangle soup with no heightfield to take
    /// them from, so applying this to one logs and does nothing.
    public static let hologram = DioramaEffect(kind: .hologram(.standard))

    /// A hologram with a specific look.
    public static func hologram(_ style: HologramStyle) -> DioramaEffect {
        DioramaEffect(kind: .hologram(style))
    }

    /// A hand-drawn look: inked outlines, flat colour, and a plain grey block of earth.
    ///
    /// Only the raster terrain chunk carries it. The lines are traced from the chunk's own triangles
    /// — where the surface ends, and where it folds — and a photorealistic 3D Tiles model is
    /// triangle soup with no single surface to trace, so applying this to one logs and does nothing.
    public static let ink = DioramaEffect(kind: .ink(.standard))

    /// An ink treatment with a specific look.
    public static func ink(_ style: InkStyle) -> DioramaEffect {
        DioramaEffect(kind: .ink(style))
    }

    /// A model-maker's look: the terrain cut into stacked flat steps and painted by height.
    ///
    /// Only the raster terrain chunk carries it. The steps are the chunk's own surface quantized in
    /// height, and a photorealistic 3D Tiles model is triangle soup with no heightfield to quantize,
    /// so applying this to one logs and does nothing.
    public static let terraced = DioramaEffect(kind: .terraced(.standard))

    /// A terraced treatment with a specific look.
    public static func terraced(_ style: TerraceStyle) -> DioramaEffect {
        DioramaEffect(kind: .terraced(style))
    }

    /// The color a view should sit the diorama against, or `nil` when the effect has no opinion.
    ///
    /// An effect that draws its own light needs darkness behind it to read — the contours are the
    /// brightest thing in the scene only if nothing else is. Platform views apply this; visionOS
    /// ignores it, because a volumetric window has the user's room behind it by design.
    public var backgroundColor: Color? {
        switch kind {
        case .none:
            return nil
        case .hologram(let style):
            return style.surfaceColor
        case .ink(let style):
            return style.paperColor
        case .terraced(let style):
            return style.backgroundColor
        }
    }
}

// MARK: - Modifier

/// View modifier that applies a visual effect to a diorama.
struct DioramaEffectModifier: ViewModifier {
    let effect: DioramaEffect

    public func body(content: Content) -> some View {
        content.environment(\.dioramaEffect, effect)
    }
}

extension View {
    /// Applies a visual effect to this diorama.
    ///
    /// ```swift
    /// DioramaView(configuration: config)
    ///     .dioramaEffect(.hologram)
    /// ```
    ///
    /// The effect is re-applied when it changes, without reloading the terrain.
    public func dioramaEffect(_ effect: DioramaEffect) -> some View {
        modifier(DioramaEffectModifier(effect: effect))
    }
}

// MARK: - Environment Key

extension EnvironmentValues {
    @Entry var dioramaEffect: DioramaEffect = .none
}
