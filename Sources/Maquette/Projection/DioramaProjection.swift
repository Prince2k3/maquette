import CoreLocation
import Foundation
import simd

/// The one place a geographic coordinate becomes a point on the table.
///
/// A diorama is a piece of the earth at a stated scale, so *every* placement question — where a pin
/// goes, where a route ribbon runs, where an outline is cut — is the same question asked of the same
/// mapping. Before this protocol the library answered it four different ways: the raster chunk
/// through `TerrainAnchor`'s Web Mercator, the photorealistic path through the WGS84 ellipsoid,
/// annotations through a 6 371 km sphere that knew about neither, and `Coordinate` itself through a
/// flat-earth offset. Three of those disagree with whatever geometry they are placed against, and
/// they disagree *silently*: a pin a few metres off the peak it names still looks like a pin on a
/// mountain.
///
/// So a projection is chosen once, by the pipeline that built the geometry, and everything
/// downstream asks it rather than doing its own trigonometry.
///
/// **This is placement, not measurement.** "How far apart are these two places" is a question about
/// the earth and belongs to ``Turf``, which answers it on a sphere and never looks at the diorama.
/// "Where does this place sit on the table" is a question about *this* diorama's scale, centre and
/// terrain, and belongs here. The two use different earth models on purpose.
///
/// ### The coordinate frame
///
/// Diorama space is RealityKit's: **+X east, +Z south, +Y up**, in diorama metres. Y = 0 is the
/// lowest terrain elevation in the region, the convention `TerrainHeightField` defines and
/// everything else in the library shares.
public protocol DioramaProjection: Sendable {
    /// Where a coordinate falls on the diorama's horizontal plane, in diorama metres.
    ///
    /// Always defined, including well outside the chunk — a point beyond the outline still has a
    /// place, it simply is not on the model, and the caller decides whether that matters. Clipping
    /// a line to the outline needs the outside vertices to have positions.
    ///
    /// The result already accounts for panning: it is where the coordinate is *drawn*, not where it
    /// would be drawn if the ground had not moved.
    func point(for coordinate: Coordinate) -> SIMD2<Float>

    /// How far the ground has slid beneath the diorama's outline, in diorama metres.
    ///
    /// Both pipelines pan, and both pan the same way — the outline stays put and the world moves
    /// under it — so this belongs to the mapping rather than to either implementation. A caller
    /// that panned the diorama sets this and everything placed through the projection follows the
    /// ground it was placed on.
    var panOffset: SIMD2<Float> { get set }

    /// The height of the diorama's surface beneath a drawn horizontal point, or `nil` where the
    /// diorama holds no ground there.
    ///
    /// `nil` is the honest answer for a coordinate outside the loaded region, and it is why
    /// ``position(for:)`` is optional. Returning 0 instead would bury pins at the base of the chunk
    /// and make the failure look like a placement bug.
    func surfaceY(atX x: Float, z: Float) -> Float?

    /// The diorama Y an absolute elevation sits at, in metres above sea level.
    ///
    /// Affine in both conformers — the diorama is a linear vertical scaling of the real relief —
    /// but the baseline and the scale differ, which is exactly why it is asked of the projection
    /// rather than computed at the call site.
    func y(forElevation meters: Double) -> Float
}

extension DioramaProjection {
    /// Where a coordinate sits on the diorama's surface, or `nil` where there is no ground.
    ///
    /// Any altitude the coordinate carries is ignored: this is the clamp-to-ground answer, which is
    /// what an unadorned pin wants. Use ``position(for:altitude:)`` to honour one.
    public func position(for coordinate: Coordinate) -> SIMD3<Float>? {
        let point = point(for: coordinate)
        guard let y = surfaceY(atX: point.x, z: point.y) else { return nil }
        return SIMD3(point.x, y, point.y)
    }

    /// Where a coordinate sits under a given altitude interpretation.
    ///
    /// - Returns: `nil` only when the interpretation needs ground the diorama does not have.
    ///   ``AltitudeReference/absolute`` never does, so a feature with a real elevation can be placed
    ///   over a hole in the terrain.
    public func position(
        for coordinate: Coordinate,
        altitude reference: AltitudeReference
    ) -> SIMD3<Float>? {
        let point = point(for: coordinate)
        let height = coordinate.altitude ?? 0

        switch reference {
        case .clampToGround:
            guard let ground = surfaceY(atX: point.x, z: point.y) else { return nil }
            return SIMD3(point.x, ground, point.y)
        case .relativeToGround:
            guard let ground = surfaceY(atX: point.x, z: point.y) else { return nil }
            // A height above the ground is a real distance, so it shrinks by the same factor the
            // relief does. Taking the difference of two elevations gets that factor out of the
            // projection without asking it for one.
            let rise = y(forElevation: height) - y(forElevation: 0)
            return SIMD3(point.x, ground + rise, point.y)
        case .absolute:
            return SIMD3(point.x, y(forElevation: height), point.y)
        }
    }

    /// Convenience for the CoreLocation type the platform views still speak.
    public func position(for coordinate: CLLocationCoordinate2D) -> SIMD3<Float>? {
        position(for: Coordinate(coordinate))
    }

    /// Where a coordinate falls on the horizontal plane, in CoreLocation terms.
    public func point(for coordinate: CLLocationCoordinate2D) -> SIMD2<Float> {
        point(for: Coordinate(coordinate))
    }
}

/// What an altitude on a coordinate is measured from.
///
/// GeoJSON positions are two- or three-dimensional and the RFC says nothing about what the third
/// number means for rendering, so the *feature* carries a number and the *style* says how to read
/// it. Without this, a route flown at 500 m and a route walked on the ground are indistinguishable,
/// and the library's previous answer — ignore altitude entirely — made every three-dimensional
/// dataset render flat.
public enum AltitudeReference: String, Sendable, Codable, CaseIterable {
    /// Ignore the altitude and sit on the surface. The default, and what an unadorned pin wants.
    case clampToGround
    /// Treat the altitude as a height above the surface directly below.
    case relativeToGround
    /// Treat the altitude as an elevation above sea level, ground or no ground.
    case absolute
}
