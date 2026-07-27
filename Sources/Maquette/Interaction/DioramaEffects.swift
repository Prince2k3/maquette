import Foundation
import SwiftUI

/// How far apart a hologram's elevation contours sit.
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

/// The look of the `.hologram` effect.
///
/// Every length here is a fraction of the chunk's largest horizontal extent rather than an absolute
/// measurement, so a style reads the same on a tabletop diorama and a room-scale one.
public struct HologramStyle: Sendable, Equatable {
    /// Color of the contour lines, the graticule, and the motes.
    public var tint: Color
    /// Color of the chunk's body beneath the lines.
    public var surfaceColor: Color
    /// Opacity of the chunk's body, in `0...1`.
    ///
    /// Values below about `0.9` let the far side of the chunk show through, which reads as a
    /// projected volume — but RealityKit sorts transparent geometry per-object rather than
    /// per-triangle, so the lower it goes the more the walls and surface visibly fight over which is
    /// in front. The default keeps the body nearly opaque and lets the lines do the work.
    public var surfaceOpacity: Float
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
    /// Number of motes suspended above the chunk. `0` draws none.
    public var moteCount: Int
    /// Whether to keep the satellite imagery beneath the effect instead of replacing it with
    /// `surfaceColor`.
    public var showsImagery: Bool

    /// Creates a hologram style.
    public init(
        tint: Color = Color(red: 0.25, green: 0.95, blue: 0.94),
        surfaceColor: Color = Color(red: 0.012, green: 0.055, blue: 0.085),
        surfaceOpacity: Float = 0.92,
        contours: ContourInterval = .automatic(count: 22),
        lineWidth: Float = 0.0035,
        glowWidth: Float = 3.5,
        glowOpacity: Float = 0.18,
        graticuleDivisions: Int = 12,
        moteCount: Int = 140,
        showsImagery: Bool = false
    ) {
        self.tint = tint
        self.surfaceColor = surfaceColor
        self.surfaceOpacity = max(0, min(1, surfaceOpacity))
        self.contours = contours
        self.lineWidth = max(0, lineWidth)
        self.glowWidth = max(1, glowWidth)
        self.glowOpacity = max(0, min(1, glowOpacity))
        self.graticuleDivisions = max(0, graticuleDivisions)
        self.moteCount = max(0, moteCount)
        self.showsImagery = showsImagery
    }

    /// Cyan contours on a near-black body. The default.
    public static let standard = HologramStyle()

    /// A denser, colder read with a tighter contour interval and no motes.
    public static let survey = HologramStyle(
        tint: Color(red: 0.55, green: 0.85, blue: 1.0),
        contours: .automatic(count: 40),
        lineWidth: 0.0022,
        glowWidth: 2.5,
        glowOpacity: 0.12,
        graticuleDivisions: 20,
        moteCount: 0
    )

    /// Amber lines, in the register of an older display.
    public static let amber = HologramStyle(
        tint: Color(red: 1.0, green: 0.68, blue: 0.22),
        surfaceColor: Color(red: 0.06, green: 0.035, blue: 0.01),
        contours: .automatic(count: 18),
        graticuleDivisions: 8
    )
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
        }
    }
}

// MARK: - Modifier

/// View modifier that applies a visual effect to a diorama.
public struct DioramaEffectModifier: ViewModifier {
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
