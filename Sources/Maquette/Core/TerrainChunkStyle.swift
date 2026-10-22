import Foundation
import SwiftUI

/// How much earth sits beneath the terrain surface.
///
/// Requests a flat floor this far below diorama Y = 0. Rendered raster chunks always limit earth
/// padding below their lowest visible terrain to 10% of their largest horizontal extent.
/// The underside stays flat, and real terrain relief can create taller cut walls.
public enum ChunkBaseDepth: Sendable, Equatable {
    /// Depth as a fraction of the chunk's largest horizontal extent.
    ///
    /// Keeps the chunk's proportions stable regardless of how large the diorama is.
    case proportional(Float)

    /// Depth in diorama-space meters.
    case absolute(Float)

    /// Depth as a multiple of the terrain's own vertical relief, with a proportional floor so
    /// flat regions still read as a solid block rather than a sheet.
    case matchingRelief(multiple: Float, minimumProportion: Float)

    /// Resolves the depth to diorama-space meters.
    ///
    /// - Parameters:
    ///   - horizontalExtent: The chunk's largest horizontal dimension in diorama meters.
    ///   - relief: The terrain's vertical relief in diorama meters.
    public func resolved(horizontalExtent: Float, relief: Float) -> Float {
        switch self {
        case .proportional(let fraction):
            return max(0, horizontalExtent * fraction)
        case .absolute(let meters):
            return max(0, meters)
        case .matchingRelief(let multiple, let minimumProportion):
            return max(relief * multiple, horizontalExtent * minimumProportion)
        }
    }
}

/// A single horizontal band of material in a chunk's cross-section.
public struct StrataBand: Sendable, Equatable {
    /// Color of the band.
    public var color: Color
    /// Relative thickness. Bands are normalized against the sum of all thicknesses in a palette.
    public var thickness: Float

    /// Creates a strata band.
    public init(color: Color, thickness: Float = 1.0) {
        self.color = color
        self.thickness = max(0, thickness)
    }
}

/// An ordered set of geological bands painted onto a chunk's cut walls, listed from the
/// deepest layer to the surface layer.
public struct StrataPalette: Sendable, Equatable {
    /// Bands ordered bottom (deepest) to top (surface).
    public var bands: [StrataBand]
    /// Amount of per-band vertical noise, as a fraction of band thickness. `0` gives crisp
    /// horizontal lines; higher values give a more irregular, natural cut.
    public var irregularity: Float

    /// Creates a strata palette.
    public init(bands: [StrataBand], irregularity: Float = 0.35) {
        self.bands = bands
        self.irregularity = max(0, min(1, irregularity))
    }

    /// Temperate soil over clay and bedrock. The default cross-section.
    public static let earth = StrataPalette(bands: [
        StrataBand(color: Color(red: 0.28, green: 0.26, blue: 0.25), thickness: 2.6),
        StrataBand(color: Color(red: 0.40, green: 0.34, blue: 0.29), thickness: 1.5),
        StrataBand(color: Color(red: 0.52, green: 0.42, blue: 0.32), thickness: 1.1),
        StrataBand(color: Color(red: 0.44, green: 0.34, blue: 0.24), thickness: 0.7),
        StrataBand(color: Color(red: 0.34, green: 0.26, blue: 0.18), thickness: 0.5),
    ])

    /// Warm banded sandstone, in the register of desert canyon walls.
    public static let canyon = StrataPalette(bands: [
        StrataBand(color: Color(red: 0.42, green: 0.24, blue: 0.18), thickness: 2.2),
        StrataBand(color: Color(red: 0.66, green: 0.36, blue: 0.22), thickness: 1.0),
        StrataBand(color: Color(red: 0.78, green: 0.50, blue: 0.30), thickness: 1.4),
        StrataBand(color: Color(red: 0.60, green: 0.33, blue: 0.21), thickness: 0.8),
        StrataBand(color: Color(red: 0.80, green: 0.58, blue: 0.38), thickness: 0.6),
    ], irregularity: 0.5)

    /// Cold grey rock with a thin soil cap, for high-alpine regions.
    public static let alpine = StrataPalette(bands: [
        StrataBand(color: Color(red: 0.22, green: 0.23, blue: 0.26), thickness: 3.0),
        StrataBand(color: Color(red: 0.34, green: 0.35, blue: 0.38), thickness: 1.6),
        StrataBand(color: Color(red: 0.46, green: 0.47, blue: 0.50), thickness: 0.9),
        StrataBand(color: Color(red: 0.30, green: 0.29, blue: 0.28), thickness: 0.5),
    ], irregularity: 0.25)

    /// Pale ice over dark rock.
    public static let arctic = StrataPalette(bands: [
        StrataBand(color: Color(red: 0.20, green: 0.22, blue: 0.27), thickness: 2.0),
        StrataBand(color: Color(red: 0.42, green: 0.50, blue: 0.58), thickness: 1.2),
        StrataBand(color: Color(red: 0.68, green: 0.78, blue: 0.85), thickness: 1.4),
        StrataBand(color: Color(red: 0.85, green: 0.91, blue: 0.95), thickness: 0.8),
    ], irregularity: 0.2)
}

/// How the chunk's cut walls are painted.
public enum ChunkWallStyle: Sendable, Equatable {
    /// Layered geological bands generated procedurally from a palette.
    case strata(StrataPalette)
    /// A single flat color.
    case solid(Color)
    /// No walls. The terrain renders as an open surface with no earth beneath it.
    case none
}

/// An optional display base sitting beneath the chunk.
public enum ChunkBaseStyle: Sendable, Equatable {
    /// The chunk floats on its own with no base.
    case none
    /// A slab beneath the chunk.
    ///
    /// - Parameters:
    ///   - color: Slab color.
    ///   - height: Slab thickness in diorama meters.
    ///   - inset: How far the slab is inset from the chunk's silhouette, in diorama meters.
    ///     Negative values make the slab overhang.
    case plinth(color: Color, height: Float, inset: Float)
}

/// The configurable appearance of the terrain chunk: how deep it is, how its cut walls read,
/// and what it sits on.
public struct TerrainChunkStyle: Sendable, Equatable {
    /// How much earth sits beneath the terrain surface.
    public var baseDepth: ChunkBaseDepth
    /// How the cut walls are painted.
    public var wall: ChunkWallStyle
    /// Whether to close the chunk with a bottom face. Disable when the chunk always rests on
    /// an opaque surface and the underside is never visible.
    public var closesBottom: Bool
    /// Color of the bottom face.
    public var bottomColor: Color
    /// An optional display base beneath the chunk.
    public var base: ChunkBaseStyle

    /// Creates a chunk style.
    public init(
        baseDepth: ChunkBaseDepth = .matchingRelief(multiple: 0.8, minimumProportion: 0.12),
        wall: ChunkWallStyle = .strata(.earth),
        closesBottom: Bool = true,
        bottomColor: Color = Color(red: 0.16, green: 0.15, blue: 0.14),
        base: ChunkBaseStyle = .none
    ) {
        self.baseDepth = baseDepth
        self.wall = wall
        self.closesBottom = closesBottom
        self.bottomColor = bottomColor
        self.base = base
    }

    /// A solid earth chunk with layered walls. The default.
    public static let standard = TerrainChunkStyle()

    /// A shallow terrain slice with dramatic canyon strata.
    public static let canyon = TerrainChunkStyle(
        baseDepth: .proportional(0.25),
        wall: .strata(.canyon)
    )

    /// A shallow slice with cool grey rock.
    public static let alpine = TerrainChunkStyle(
        baseDepth: .matchingRelief(multiple: 0.5, minimumProportion: 0.08),
        wall: .strata(.alpine)
    )

    /// Terrain surface only, with no earth beneath it.
    public static let surfaceOnly = TerrainChunkStyle(
        baseDepth: .absolute(0),
        wall: .none,
        closesBottom: false
    )
}
