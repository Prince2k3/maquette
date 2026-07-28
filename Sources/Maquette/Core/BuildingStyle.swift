import Foundation
import SwiftUI

/// Buildings standing on the chunk's terrain, extruded from OpenStreetMap footprints.
///
/// The terrain itself cannot supply them: both elevation providers are bare-earth models with
/// structures removed, and a heightfield holds one Y per horizontal position, so it could not
/// express a vertical wall even if they were present. Buildings are therefore a separate fetch and
/// separate geometry resting on the ground.
///
/// > Important: ``source`` defaults to the public Overpass API, which needs no key and is slow
/// > enough — tens of seconds when its instances are busy — that a shipping diorama wants
/// > ``BuildingSource/mapTiler(apiKey:)`` instead.
public struct BuildingStyle: Sendable, Equatable {
    /// Where the footprints are fetched from.
    public var source: BuildingSource
    /// Color the blocks are drawn in.
    public var color: Color
    /// Opacity of the blocks, in `0...1`. Below `1` they blend, and RealityKit sorts transparent
    /// geometry per object, so buildings will argue with the chunk's own surfaces over depth.
    public var opacity: Float
    /// Height drawn for a footprint whose tags give neither a height nor a storey count.
    public var defaultHeightMeters: Double
    /// Height assumed per storey when only `building:levels` is tagged.
    public var metersPerLevel: Double
    /// Multiplies every building's height, on top of the terrain's own exaggeration.
    ///
    /// A block of flats is around 15 m against terrain relief measured in hundreds, so at true scale
    /// a city reads as a texture rather than as buildings. Exaggerating them is the same concession
    /// `elevationExaggeration` makes for the ground, made separately because the two want very
    /// different numbers.
    public var exaggeration: Float
    /// Smallest height, in diorama meters, a building is drawn at.
    ///
    /// A footprint whose scaled height rounds to nothing draws a flat sheet that z-fights the
    /// terrain, which is worse than drawing it a little too tall.
    public var minimumDrawnHeight: Float
    /// Whether buildings track the pan offset, so they stay over the ground they belong to.
    public var followsPan: Bool
    /// Whether the blocks are drawn.
    ///
    /// A switch, not a scope: `nil` buildings on a ``DioramaConfiguration`` are never fetched, while
    /// `isVisible == false` keeps the fetch and the arena and only stops drawing them. Turning them
    /// back on therefore costs nothing — no query, no re-extrude, no reload — which is what makes
    /// this usable as a live toggle rather than as a load-time decision.
    ///
    /// While they are off, the per-pan re-select and the pan refetch stand down too, since both exist
    /// only to keep what is drawn correct. Both are brought back up to date when they come on.
    public var isVisible: Bool
    /// Most footprints to fetch. The drop is logged when it bites.
    public var maximumBuildings: Int

    /// Creates a building style.
    public init(
        source: BuildingSource = .openStreetMap,
        color: Color = Color(red: 0.35, green: 0.95, blue: 0.95),
        opacity: Float = 0.55,
        defaultHeightMeters: Double = 8,
        metersPerLevel: Double = 3.2,
        exaggeration: Float = 1,
        minimumDrawnHeight: Float = 0.0015,
        followsPan: Bool = true,
        isVisible: Bool = true,
        maximumBuildings: Int = 12_000
    ) {
        self.source = source
        self.color = color
        self.opacity = max(0, min(1, opacity))
        self.defaultHeightMeters = max(0, defaultHeightMeters)
        self.metersPerLevel = max(0, metersPerLevel)
        self.exaggeration = max(0, exaggeration)
        self.minimumDrawnHeight = max(0, minimumDrawnHeight)
        self.followsPan = followsPan
        self.isVisible = isVisible
        self.maximumBuildings = max(0, maximumBuildings)
    }

    /// Translucent cyan blocks, to sit under the hologram effect. The default.
    public static let standard = BuildingStyle()

    /// Opaque pale blocks, for a diorama drawn without an effect.
    public static let solid = BuildingStyle(
        color: Color(red: 0.86, green: 0.86, blue: 0.88),
        opacity: 1
    )

    /// Converts a real-world height in meters into diorama meters.
    ///
    /// Runs through the height field's own `elevationScale`, so a building and the terrain it stands
    /// on are measured against the same vertical ruler — including the region's
    /// `elevationExaggeration`, which is why `exaggeration` here multiplies rather than replaces.
    func verticalScale(of heightField: TerrainHeightField) -> Float {
        heightField.elevationScale * exaggeration
    }
}
