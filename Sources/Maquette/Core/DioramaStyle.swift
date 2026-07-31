import Foundation
import SwiftUI

/// What the diorama is made of and how the substrate is built — the parallel of MapKit's
/// `MapStyle`, applied with ``SwiftUICore/View/dioramaStyle(_:)``.
///
/// A style change *reloads* — it decides which tiles are fetched and how the solid is generated.
/// The things that merely repaint a chunk already in hand are a ``DioramaEffect``, applied with
/// `dioramaEffect(_:)`; the two stay separate because they cost different things.
public struct DioramaStyle: Sendable {
    var elevation: ElevationStyle
    var elevationExaggeration: Float
    var imagerySource: ImagerySource
    var elevationSource: ElevationSource
    var chunk: TerrainChunkStyle
    var buildings: BuildingStyle?
    var panRange: Float
    var zoomLevel: Int?
    var presentation: DioramaPresentation

    /// The default terrain chunk: realistic elevation, ESRI imagery, standard strata.
    public static let standard = DioramaStyle.standard()

    init(
        elevation: ElevationStyle,
        elevationExaggeration: Float,
        imagerySource: ImagerySource,
        elevationSource: ElevationSource,
        chunk: TerrainChunkStyle,
        buildings: BuildingStyle?,
        panRange: Float,
        zoomLevel: Int?,
        presentation: DioramaPresentation
    ) {
        self.elevation = elevation
        self.elevationExaggeration = elevationExaggeration
        self.imagerySource = imagerySource
        self.elevationSource = elevationSource
        self.chunk = chunk
        self.buildings = buildings
        self.panRange = panRange
        self.zoomLevel = zoomLevel
        self.presentation = presentation
    }

    /// Recovers the style half of a configuration, for change comparison.
    init(configuration: DioramaConfiguration) {
        self.init(
            elevation: configuration.elevation,
            elevationExaggeration: configuration.elevationExaggeration,
            imagerySource: configuration.imagerySource,
            elevationSource: configuration.elevationSource,
            chunk: configuration.chunk,
            buildings: configuration.buildings,
            panRange: configuration.panRange,
            zoomLevel: configuration.zoomLevel,
            presentation: configuration.presentation
        )
    }

    /// A terrain chunk built from elevation and imagery tiles.
    ///
    /// - Parameters:
    ///   - elevation: Whether terrain relief is rendered. Defaults to realistic.
    ///   - exaggeration: Multiplier applied to elevation values. `1.0` is true-to-scale.
    ///   - imagery: Source for satellite imagery. Defaults to ESRI World Imagery (free).
    ///   - elevationSource: Source for elevation data. Defaults to Mapzen Terrarium (free).
    ///   - chunk: Appearance of the solid: base depth, cut walls, strata, display base.
    ///   - buildings: OSM building extrusion, or `nil` for none.
    ///   - panRange: Ground kept loaded beyond the outline, as a fraction of the chunk's extent.
    ///     `0` disables panning; on a terrain chunk this is a margin, not a limit.
    ///   - zoomLevel: Explicit tile zoom, or `nil` to derive it from the region's radius.
    public static func standard(
        elevation: ElevationStyle = .realistic,
        exaggeration: Float = 1.0,
        imagery: ImagerySource = .esriSatellite,
        elevationSource: ElevationSource = .mapzen,
        chunk: TerrainChunkStyle = .standard,
        buildings: BuildingStyle? = nil,
        panRange: Float = 0,
        zoomLevel: Int? = nil
    ) -> DioramaStyle {
        DioramaStyle(
            elevation: elevation,
            elevationExaggeration: exaggeration,
            imagerySource: imagery,
            elevationSource: elevationSource,
            chunk: chunk,
            buildings: buildings,
            panRange: panRange,
            zoomLevel: zoomLevel,
            presentation: .terrainChunk
        )
    }

    /// A photorealistic model streamed from OGC 3D Tiles and cut to the outline.
    ///
    /// Terrain-chunk options do not apply; `style` carries everything that does.
    public static func photorealistic(
        provider: any Tiles3DProvider,
        style: Tiles3DStyle = .standard,
        panRange: Float = 0
    ) -> DioramaStyle {
        DioramaStyle(
            elevation: .realistic,
            elevationExaggeration: 1,
            imagerySource: .esriSatellite,
            elevationSource: .mapzen,
            chunk: .standard,
            buildings: nil,
            panRange: panRange,
            zoomLevel: nil,
            presentation: .photorealistic(provider: provider, style: style)
        )
    }
}

extension DioramaStyle: Equatable {
    /// Component-wise, with the photorealistic provider compared by type and attribution — the
    /// closest an `any Tiles3DProvider` gets to equality. Two different providers of the same type
    /// and attribution read as equal, which for reload-diffing errs on the side of not reloading.
    public static func == (lhs: DioramaStyle, rhs: DioramaStyle) -> Bool {
        guard lhs.elevation == rhs.elevation,
              lhs.elevationExaggeration == rhs.elevationExaggeration,
              lhs.imagerySource == rhs.imagerySource,
              lhs.elevationSource == rhs.elevationSource,
              lhs.chunk == rhs.chunk,
              lhs.buildings == rhs.buildings,
              lhs.panRange == rhs.panRange,
              lhs.zoomLevel == rhs.zoomLevel
        else { return false }
        switch (lhs.presentation, rhs.presentation) {
        case (.terrainChunk, .terrainChunk):
            return true
        case (.photorealistic(let lp, let ls), .photorealistic(let rp, let rs)):
            return type(of: lp) == type(of: rp) && lp.attribution == rp.attribution && ls == rs
        default:
            return false
        }
    }
}

extension View {
    /// Sets the substrate style for dioramas in this hierarchy.
    ///
    /// ```swift
    /// DioramaView(region: region)
    ///     .dioramaStyle(.standard(chunk: .canyon, panRange: 0.6))
    /// ```
    public func dioramaStyle(_ style: DioramaStyle) -> some View {
        environment(\.dioramaStyle, style)
    }
}

extension EnvironmentValues {
    @Entry var dioramaStyle: DioramaStyle = .standard
}
