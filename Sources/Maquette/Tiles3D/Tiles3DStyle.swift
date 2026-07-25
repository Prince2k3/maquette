import Foundation
import SwiftUI

/// What a photorealistic model rests on.
///
/// Photogrammetry is a skin with nothing behind it, so the base is structural rather than
/// decorative: it is what stops the model reading as hollow when seen from a low angle, and it
/// hides the open faces left where the geometry was cut to the outline.
public enum Tiles3DBase: Sendable, Equatable {
    /// No base. The model's cut faces and hollow underside are visible from below.
    case none
    /// A slab beneath the model, following the diorama's outline.
    ///
    /// - Parameters:
    ///   - color: Slab color.
    ///   - thickness: Slab thickness in diorama meters.
    ///   - inset: How far the slab is inset from the outline, in diorama meters. Negative values
    ///     make it overhang, which reads as a tray holding the model.
    case tray(color: Color, thickness: Float, inset: Float)
}

/// The appearance and streaming behaviour of a photorealistic 3D Tiles model.
///
/// Deliberately separate from `TerrainChunkStyle`: a chunk's vocabulary — earth depth, geological
/// strata, a closing bottom face — presumes a heightfield that can be extruded, and none of it has
/// meaning for streamed photogrammetry.
public struct Tiles3DStyle: Sendable, Equatable {
    /// Whether to cut the model down to the diorama's outline.
    ///
    /// Tiles arrive on their own grid, so without clipping the model spills past the intended
    /// region in ragged rectangles.
    public var clipsToBoundary: Bool
    /// What the model rests on.
    public var base: Tiles3DBase
    /// Screen-space error threshold driving level of detail. Lower fetches more, finer tiles.
    public var detailThreshold: Double

    /// Creates a photorealistic style.
    public init(
        clipsToBoundary: Bool = true,
        base: Tiles3DBase = .tray(
            color: Color(red: 0.13, green: 0.13, blue: 0.14),
            thickness: 0.025,
            inset: -0.015
        ),
        detailThreshold: Double = 16
    ) {
        self.clipsToBoundary = clipsToBoundary
        self.base = base
        self.detailThreshold = max(1, detailThreshold)
    }

    /// A clipped model on an overhanging tray. The default.
    public static let standard = Tiles3DStyle()

    /// Higher detail, at the cost of fetching more tiles.
    public static let detailed = Tiles3DStyle(detailThreshold: 8)

    /// The raw streamed tileset, uncut and unsupported, as it arrives from the provider.
    public static let unbounded = Tiles3DStyle(clipsToBoundary: false, base: .none)
}
