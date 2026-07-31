import CoreLocation
import Foundation

/// Where on Earth the diorama shows: a centre and the radius of ground around it.
///
/// The parallel of MapKit's `MKCoordinateRegion`, in the vocabulary a diorama actually uses — a
/// chunk is cut from a disc of ground, so its region is a centre and a radius rather than spans.
///
/// A region is live: handing ``DioramaView`` a different one relocates or reloads the diorama in
/// place, the way changing a `Map`'s position moves the map.
public struct DioramaRegion: Sendable, Equatable {
    /// Geographic centre of the diorama.
    public var center: Coordinate
    /// Radius in meters around the centre to include.
    public var radius: Double

    /// Creates a region.
    public init(center: Coordinate, radius: Double) {
        self.center = center
        self.radius = radius
    }

    /// Creates a region from a CoreLocation coordinate.
    public init(center: CLLocationCoordinate2D, radius: Double) {
        self.init(center: Coordinate(center), radius: radius)
    }

    /// Creates a region framed on a real-world outline.
    ///
    /// The outline decides where the diorama is and how much ground it fetches; pair it with
    /// ``DioramaShape/geoJSON(_:)-(Geometry)`` to also cut the chunk to the same boundary:
    ///
    /// ```swift
    /// let park = try JSONDecoder().decode(FeatureCollection.self, from: data)
    /// if let region = DioramaRegion(fitting: park), let shape = DioramaShape.geoJSON(park) {
    ///     DioramaView(region: region, shape: shape)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - outline: The geometry to frame. The first polygon found is used.
    ///   - padding: Extra ground around the outline, as a fraction of its span.
    /// - Returns: `nil` when the outline holds no polygon, or when it is a single point.
    public init?(fitting outline: Geometry, padding: Double = 0.05) {
        guard let frame = GeographicFrame(fitting: outline, padding: padding) else { return nil }
        self.init(center: frame.center, radius: frame.radiusMeters)
    }

    /// Creates a region framed on the first polygon in a decoded GeoJSON document.
    public init?(fitting collection: FeatureCollection, padding: Double = 0.05) {
        // Framed on the polygon that would be cut to, not on the whole document: a boundary file
        // that also carries labels or a route would otherwise fetch the ground those reach across.
        guard let geometry = collection.features.lazy.compactMap(\.geometry)
            .first(where: { DioramaShape.geoJSON($0) != nil })
        else { return nil }
        self.init(fitting: geometry, padding: padding)
    }
}
