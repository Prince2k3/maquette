import Foundation
import SwiftUI

/// What a photorealistic model rests on.
///
/// Photogrammetry is a skin with nothing behind it, so the base is structural rather than
/// decorative: a surface-following underside and tray band close the cut rim. Earth plus tray
/// share the same ten-percent-of-width thickness limit as raster chunks; arbitrary holes in
/// source photogrammetry are not repaired.
public enum Tiles3DBase: Sendable, Equatable {
    /// No base. The model's hollow underside is visible from below, and the cut wall has no floor
    /// to stop at other than the model's own lowest ground.
    case none
    /// A slab beneath the model, following the diorama's outline.
    ///
    /// - Parameters:
    ///   - color: Slab color.
    ///   - thickness: Requested slab thickness in diorama meters, capped at half the shared
    ///     shallow-base budget so earth and tray together stay within ten percent of chunk width.
    ///   - inset: Inset in diorama meters for an unbounded model's flat tray. Clipped shallow
    ///     bases share the selected cut outline exactly, so this value does not offset them.
    case tray(color: Color, thickness: Float, inset: Float)
}

/// The appearance and streaming behaviour of a photorealistic 3D Tiles model.
///
/// Mostly separate from `TerrainChunkStyle`, and deliberately so: earth depth and a closing bottom
/// face presume a heightfield that can be extruded, and neither has meaning for streamed
/// photogrammetry, which is arbitrary triangle soup with nothing behind it.
///
/// The cut wall is the exception, and it reuses `ChunkWallStyle` outright. Both pipelines end up
/// slicing through ground and showing the slice, so the vocabulary genuinely coincides there —
/// giving this path its own near-identical wall enum would have been a distinction without a
/// difference.
public struct Tiles3DStyle: Sendable, Equatable {
    /// Whether to cut the model down to the diorama's outline.
    ///
    /// Tiles arrive on their own grid, so without clipping the model spills past the intended
    /// region in ragged rectangles.
    public var clipsToBoundary: Bool
    /// How the cut edge reads where the model was sliced to the outline.
    ///
    /// Only meaningful alongside `clipsToBoundary`: an uncut model has no cut to close. Setting
    /// `.none` leaves the silhouette open, which reads as a hollow shell wherever the model's
    /// relief is deeper than the tray is thick.
    public var wall: ChunkWallStyle
    /// What the model rests on.
    public var base: Tiles3DBase
    /// Screen-space error threshold driving level of detail. Lower fetches more, finer tiles.
    public var detailThreshold: Double

    /// Creates a photorealistic style.
    public init(
        clipsToBoundary: Bool = true,
        wall: ChunkWallStyle = .strata(.earth),
        base: Tiles3DBase = .tray(
            color: Color(red: 0.13, green: 0.13, blue: 0.14),
            thickness: 0.025,
            inset: -0.015
        ),
        detailThreshold: Double = 16
    ) {
        self.clipsToBoundary = clipsToBoundary
        self.wall = wall
        self.base = base
        self.detailThreshold = max(1, detailThreshold)
    }

    /// A clipped model on an overhanging tray. The default.
    public static let standard = Tiles3DStyle()

    /// Higher detail, at the cost of fetching more tiles.
    public static let detailed = Tiles3DStyle(detailThreshold: 8)

    /// The raw streamed tileset, uncut and unsupported, as it arrives from the provider.
    public static let unbounded = Tiles3DStyle(clipsToBoundary: false, wall: .none, base: .none)
}
