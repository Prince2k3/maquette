import CoreLocation
import Foundation
import simd

/// Places coordinates on the photorealistic model, through the ellipsoid the tiles are positioned
/// against.
///
/// OGC 3D Tiles arrive in ECEF, and `Tiles3DEntity` brings them onto the table with exactly two
/// operations: rotate into the local ENU frame about the diorama's centre, and scale by
/// `physicalSize / (radiusMeters * 2)`. This does the same two, so a coordinate lands in the
/// frame its geometry arrived in rather than near it.
///
/// The difference from a spherical approximation is not academic. WGS84's flattening moves a point
/// by a fraction of a percent of its distance from the centre, which on a city block is under a
/// metre — but the model is *photogrammetry*, so a metre is the difference between a pin on a
/// building and a pin in the street beside it, and the error grows with the radius.
struct EllipsoidProjection: DioramaProjection {
    /// The ellipsoid frame, centred on the diorama.
    public let converter: ECEFConverter
    /// Diorama metres per real metre — the entity scale `Tiles3DEntity` applies.
    public let geographicScale: Float
    /// The elevation the model's datum sits at, in metres above the ellipsoid.
    ///
    /// `Tiles3DEntity` drops the model so its lowest visible ground reaches diorama Y = 0, which is
    /// the library's convention everywhere. That drop is what this records, so an absolute altitude
    /// can be turned back into a diorama height.
    public var datumElevation: Double

    /// How far the model has been slid beneath its outline, in diorama metres.
    public var panOffset: SIMD2<Float> = .zero

    /// Immutable index of the actual enabled LOD triangles, in the content's physical frame.
    var surface: OverlaySurfaceMesh?
    /// Optional test/custom sampler; absence never implies a datum-height surface.
    public var groundSampler: (@Sendable (Float, Float) -> Float?)?

    public init(
        center: CLLocationCoordinate2D,
        radiusMeters: Double,
        physicalSize: Float,
        datumElevation: Double = 0,
        panOffset: SIMD2<Float> = .zero
    ) {
        self.converter = ECEFConverter(origin: center)
        self.geographicScale = radiusMeters > 0 ? physicalSize / Float(radiusMeters * 2) : 1
        self.datumElevation = datumElevation
        self.panOffset = panOffset
    }

    public func point(for coordinate: Coordinate) -> SIMD2<Float> {
        // Altitude cannot change where a point sits horizontally in an ENU frame, so it is dropped
        // here rather than threaded through: the vertical answer is `surfaceY` and `y(forElevation:)`.
        let local = converter.local(for: coordinate.horizontal)
        return SIMD2(local.x, local.z) * geographicScale - panOffset
    }

    public func surfaceY(atX x: Float, z: Float) -> Float? {
        surface?.surfaceY(atX: x, z: z) ?? groundSampler?(x, z)
    }

    public func y(forElevation meters: Double) -> Float {
        Float(meters - datumElevation) * geographicScale
    }
}
