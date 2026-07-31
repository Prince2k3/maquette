import Foundation
import simd

/// Where the globe has to sit for a chunk of it to be the chunk on the table.
///
/// The chunk's centre coordinate is at the diorama origin, north is −Z, east is +X and up is +Y —
/// that is ``TerrainAnchor``'s mapping, where a tile's row index grows southward. A dock is the
/// rigid motion that puts the globe in exactly that frame: rotate it until the coordinate's own
/// outward normal points at +Y and its north tangent at −Z, then drop the sphere by its radius so
/// the surface point lands on the origin.
///
/// The result is that the globe's tangent plane at that coordinate **is** the chunk's Y = 0 plane,
/// so the two can be cross-faded in place rather than animated towards each other. Everything else
/// about the transition follows from this: a camera looking at the origin is looking at the same
/// ground in both, and the frame the chunk pans in and the frame the globe spins in agree.
///
/// The one thing a dock does not do is match scale, and it cannot. A 0.8 m chunk covering 12 km of
/// ground implies a globe of radius `6371008.8 × 0.8 / 12000 ≈ 424 m`, which is a sphere the size of
/// a district. The globe is therefore shown at whatever radius reads well, and the transition is a
/// dissolve rather than a continuous zoom — the scales genuinely do not meet.
public struct GlobeDock: Sendable, Equatable {
    /// The coordinate placed at the diorama origin.
    public let coordinate: Coordinate

    /// The globe's radius in diorama meters.
    public let radius: Float

    public init(coordinate: Coordinate, radius: Float) {
        self.coordinate = coordinate
        self.radius = radius
    }

    /// The globe's centre, in diorama space.
    ///
    /// Directly below the origin by the radius, whatever the coordinate — the rotation carries all
    /// of the coordinate's information, and the translation only has to lower the sphere onto the
    /// table.
    public var center: SIMD3<Float> {
        SIMD3(0, -radius, 0)
    }

    /// The rotation taking the globe's own frame into the diorama's.
    ///
    /// Built from the coordinate's east/north/up basis rather than from an axis-angle pair: two
    /// correspondences are needed, not one. Rotating the up vector onto +Y alone leaves the globe
    /// free to spin about +Y, which would put north somewhere arbitrary and silently rotate the
    /// world under a chunk that is drawn north-up.
    public var rotation: simd_quatf {
        let up = GlobeGeometry.direction(for: coordinate)
        // East is the longitude tangent and stays defined at the poles, where the north tangent's
        // usual formula degenerates; north then falls out of the cross product, orthonormal by
        // construction. ENU is right-handed with east × north = up, so north = up × east.
        let lon = coordinate.longitudeRadians
        let east = SIMD3<Float>(Float(cos(lon)), 0, Float(-sin(lon)))
        let north = simd_cross(up, east)

        let globeBasis = simd_float3x3(columns: (east, north, up))
        // East to +X, north to −Z, up to +Y. Right-handed: X × (−Z) = +Y.
        let dioramaBasis = simd_float3x3(columns: (
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 0, -1),
            SIMD3<Float>(0, 1, 0)
        ))
        return simd_quatf(dioramaBasis * globeBasis.transpose)
    }

    /// The docked transform as a matrix, for callers assembling one directly.
    public var matrix: simd_float4x4 {
        matrix(scale: 1)
    }

    /// The docked transform with the globe grown or shrunk **about the docked point**.
    ///
    /// This is what the handoff animates, and the pivot is the whole of it. ``GlobeEntity`` builds
    /// its mesh about its own origin, so the entity's origin *is* the sphere's centre — scaling the
    /// entity on its own would leave that centre where it is and slide the docked coordinate off the
    /// diorama origin, which swings the entire world under a camera that is aimed at it. Lowering the
    /// sphere by `radius · scale` instead keeps its topmost point on the origin at every size, so the
    /// globe grows out of the ground the chunk is standing on.
    ///
    /// Only the placement scales. ``dioramaPoint(for:)`` and ``coordinate(facing:)`` still answer at
    /// full size, which is right for both of their callers: steering and relocation run only once the
    /// transition has settled, where the scale is 1 by construction.
    public func matrix(scale: Float) -> simd_float4x4 {
        var transform = simd_float4x4(rotation)
        transform.columns.0 *= scale
        transform.columns.1 *= scale
        transform.columns.2 *= scale
        transform.columns.3 = SIMD4(center * scale, 1)
        return transform
    }

    /// Where a coordinate on the docked globe lands in diorama space.
    public func dioramaPoint(for coordinate: Coordinate) -> SIMD3<Float> {
        center + rotation.act(GlobeGeometry.position(for: coordinate, radius: radius))
    }

    /// The coordinate the docked globe presents towards a point in diorama space.
    ///
    /// This is how zooming back in picks its new centre: the point is the camera, and the answer is
    /// the place on the globe the user has spun round to face. It is the sub-camera point rather
    /// than a surface intersection, so it is defined even for a camera inside the sphere's shadow,
    /// and it is exactly the coordinate a rotation-only handoff keeps centred on screen.
    ///
    /// Returns `nil` only for a point at the globe's own centre, which names no direction.
    public func coordinate(facing point: SIMD3<Float>) -> Coordinate? {
        GlobeGeometry.coordinate(forDirection: rotation.inverse.act(point - center))
    }
}
