import Foundation

/// Spherical measurement and containment over GeoJSON values, following Turf.js.
///
/// Two deliberate departures from Turf, both of which would be silent if unstated:
///
/// - **Everything is in metres.** Turf's functions default to kilometres and take a `units` option;
///   this library is metric-metres throughout — `radiusMeters`, elevations, diorama extents — and a
///   distance that came back in kilometres would be wrong by a factor of a thousand in a place
///   where nothing else would flag it.
/// - **The earth is a sphere of radius ``earthRadiusMeters``**, which is Turf's mean radius. That is
///   the right model for "how far is it" and the wrong one for "where does this go on the model" —
///   placement goes through a ``DioramaProjection``, which uses the same projection the geometry
///   itself was built with. Mixing the two is how a pin ends up beside the building it names.
public enum Turf {
    /// The IUGG mean earth radius, in metres. Turf.js uses the same figure.
    public static let earthRadiusMeters: Double = 6_371_008.8

    // MARK: - Distance and direction

    /// Great-circle distance in metres, by the haversine formula.
    public static func distance(from: Coordinate, to: Coordinate) -> Double {
        let dLat = (to.latitude - from.latitude) * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let lat1 = from.latitudeRadians
        let lat2 = to.latitudeRadians

        let a = sin(dLat / 2) * sin(dLat / 2)
            + sin(dLon / 2) * sin(dLon / 2) * cos(lat1) * cos(lat2)
        return earthRadiusMeters * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// The initial compass bearing in degrees from north, in `-180...180`.
    ///
    /// "Initial" because a great circle's bearing changes as it is followed: leave London for Tokyo
    /// on a bearing of 29° and arrive on one of 149°. ``finalBearing(from:to:)`` is the other end.
    public static func bearing(from: Coordinate, to: Coordinate) -> Double {
        let lat1 = from.latitudeRadians
        let lat2 = to.latitudeRadians
        let dLon = (to.longitude - from.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }

    /// The bearing on arrival, in `-180...180`.
    public static func finalBearing(from: Coordinate, to: Coordinate) -> Double {
        normalizedBearing(bearing(from: to, to: from) + 180)
    }

    /// The point reached by travelling the given distance along a great circle.
    public static func destination(
        from origin: Coordinate,
        meters: Double,
        bearing: Double
    ) -> Coordinate {
        let angular = meters / earthRadiusMeters
        let course = bearing * .pi / 180
        let lat1 = origin.latitudeRadians
        let lon1 = origin.longitudeRadians

        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(course))
        let lon2 = lon1 + atan2(
            sin(course) * sin(angular) * cos(lat1),
            cos(angular) - sin(lat1) * sin(lat2)
        )

        return Coordinate(
            longitude: normalizedLongitude(lon2 * 180 / .pi),
            latitude: lat2 * 180 / .pi,
            altitude: origin.altitude
        )
    }

    /// The point halfway along the great circle between two coordinates.
    public static func midpoint(_ a: Coordinate, _ b: Coordinate) -> Coordinate {
        destination(from: a, meters: distance(from: a, to: b) / 2, bearing: bearing(from: a, to: b))
    }

    // MARK: - Wrapping

    /// Folds a longitude back into `-180..<180`.
    static func normalizedLongitude(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value >= 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    /// Folds a bearing back into `-180...180`.
    static func normalizedBearing(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }
}
