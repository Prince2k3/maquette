import CoreLocation
import Foundation
import simd

/// The geographic frame a real-world outline is read against: the coordinate at diorama X/Z = 0,
/// and the real-world radius that half the chunk's extent spans.
///
/// These are the same two values a chunk fetches its terrain with, which is the whole point — an
/// outline resolved through the frame the ground was fetched in lands *on* that ground rather than
/// near it. Handing a boundary a different frame from the one the terrain came from is the same
/// class of silent error the library's single projection exists to prevent: a city limit a hundred
/// metres off the city still looks like a city limit.
public struct GeographicFrame: Sendable, Equatable {
    /// The coordinate that sits at diorama X/Z = 0.
    public let center: Coordinate
    /// Real-world metres spanned by half the chunk's horizontal extent.
    public let radiusMeters: Double

    /// Creates a frame from an explicit centre and radius.
    public init(center: Coordinate, radiusMeters: Double) {
        self.center = center.horizontal
        self.radiusMeters = radiusMeters
    }

    /// Creates a frame from a CoreLocation centre and a radius.
    public init(center: CLLocationCoordinate2D, radiusMeters: Double) {
        self.init(center: Coordinate(center), radiusMeters: radiusMeters)
    }

    /// The frame that holds a geographic outline, at true scale, with room to spare.
    ///
    /// The centre is the middle of the outline's extent and the radius is half its longer side, so
    /// a chunk built with this frame contains the whole outline whichever way round it is. Feed the
    /// result straight back into ``DioramaConfiguration`` and the terrain fetched is the terrain the
    /// outline needs.
    ///
    /// Measured in Web Mercator tile space rather than on the sphere, so it agrees exactly with the
    /// mapping the outline is later resolved through — a spherical span and a Mercator one disagree
    /// by the latitude scaling, and the disagreement would show up as an outline slightly too big
    /// for the ground beneath it. The consequence is the usual one: an outline crossing the
    /// antimeridian is not supported here.
    ///
    /// - Parameters:
    ///   - geometry: The outline to frame. Any geometry works — every position it holds is used.
    ///   - padding: Extra radius as a fraction of the outline's own, so the cut edge is not flush
    ///     with the edge of the fetched region. Defaults to 5%.
    /// - Returns: `nil` when the geometry has no positions, or when they all sit on one point.
    public init?(fitting geometry: Geometry, padding: Double = 0.05) {
        let coordinates = geometry.coordinates
        guard let first = coordinates.first else { return nil }

        let zoom = Self.referenceZoom
        var lo = TileMath.tilePoint(for: first, zoom: zoom)
        var hi = lo
        for coordinate in coordinates.dropFirst() {
            let point = TileMath.tilePoint(for: coordinate, zoom: zoom)
            lo = simd_min(lo, point)
            hi = simd_max(hi, point)
        }

        let span = hi - lo
        guard span.x > 0 || span.y > 0 else { return nil }

        let center = TileMath.coordinate(forTilePoint: (lo + hi) / 2, zoom: zoom)
        let metersPerTile = TileMath.metersPerTile(latitude: center.latitude, zoom: zoom)
        let radius = max(span.x, span.y) / 2 * metersPerTile
        self.init(center: center, radiusMeters: radius * (1 + max(0, padding)))
    }
}

extension GeographicFrame {
    /// Zoom the tile-space arithmetic is carried out at.
    ///
    /// The mapping is zoom-invariant: a tile-space delta is divided by the same `metersPerTile` it
    /// was measured in, so every zoom names the same ground. One is fixed here so the arithmetic is
    /// reproducible rather than dependent on whatever zoom the tiles happened to be fetched at —
    /// which is what lets an outline be resolved before a single tile has arrived.
    static let referenceZoom = 12

    /// The anchor this frame places a chunk of the given extent with.
    func anchor(spanning extent: SIMD2<Float>) -> TerrainAnchor {
        TerrainAnchor(
            centeredOn: center,
            zoom: Self.referenceZoom,
            extent: extent,
            radiusMeters: radiusMeters
        )
    }

    /// Resolves a geographic ring into diorama-space (x, z) points.
    ///
    /// The ring is **not** re-centred or scaled to fit: it lands where the ground it names lands, so
    /// an outline offset from the frame's centre is drawn offset. Rescaling it to fill the chunk
    /// would put the cut edge somewhere the boundary does not run, which is the one thing a
    /// real-world outline is for.
    func points(for ring: LinearRing, extent: SIMD2<Float>) -> [SIMD2<Float>] {
        let anchor = anchor(spanning: extent)
        return ring.open.map { coordinate in
            let point = anchor.dioramaPoint(for: coordinate)
            return SIMD2(Float(point.x), Float(point.y))
        }
    }
}
