import CoreLocation
import Foundation
import simd

/// Places coordinates on the raster terrain chunk, through the same mapping the chunk was built
/// with.
///
/// The whole point is that it is the *same* mapping. `TerrainAnchor` names diorama X/Z against Web
/// Mercator tile space and `TerrainSolidGenerator` sampled the height field through it to make the
/// surface, so asking the anchor and the height field again cannot put a pin anywhere but on the
/// ground it names — at any zoom, after any pan, on any outline. An independent approximation, even
/// a good one, drifts against the terrain it is placed on precisely where the terrain is most
/// interesting.
public struct TerrainProjection: DioramaProjection {
    /// The surface, which carries the anchor, the elevation baseline and the vertical scale.
    public let heightField: TerrainHeightField

    /// How far the ground has slid beneath the chunk, in diorama metres.
    ///
    /// The chunk stays put and the terrain moves, so a coordinate is drawn at its anchored point
    /// *minus* the offset — and the surface beneath a drawn point is sampled at that point *plus*
    /// the offset. Getting the sign wrong here moves pins the wrong way at twice the rate, which
    /// looks like the terrain being wrong rather than the pin.
    public var panOffset: SIMD2<Float> = .zero

    public init(heightField: TerrainHeightField, panOffset: SIMD2<Float> = .zero) {
        self.heightField = heightField
        self.panOffset = panOffset
    }

    /// The tile-space mapping the chunk was generated against.
    public var anchor: TerrainAnchor { heightField.anchor }

    public func point(for coordinate: Coordinate) -> SIMD2<Float> {
        let anchored = heightField.anchor.dioramaPoint(for: coordinate)
        return SIMD2(Float(anchored.x), Float(anchored.y)) - panOffset
    }

    public func surfaceY(atX x: Float, z: Float) -> Float? {
        let ground = SIMD2(x, z) + panOffset
        guard heightField.isResident(atX: ground.x, z: ground.y) else { return nil }
        return heightField.surfaceY(atX: ground.x, z: ground.y)
    }

    public func y(forElevation meters: Double) -> Float {
        (Float(meters) - heightField.minElevation) * heightField.elevationScale
    }

    /// The surface elevation at a coordinate in diorama Y, or `nil` off the loaded region.
    public func elevation(at coordinate: CLLocationCoordinate2D) -> Float? {
        position(for: Coordinate(coordinate))?.y
    }
}
