import Foundation
import simd

// MARK: - Point in polygon

extension Turf {
    /// Whether a coordinate falls inside a polygon, holes taken out.
    ///
    /// Ray casting in longitude/latitude space, which is Turf's `booleanPointInPolygon`. It is a
    /// planar test on angles, so it answers "is this vertex inside this ring" exactly — the ring is
    /// the same list of vertices either way — while saying nothing about great-circle edges between
    /// them. For the extents a diorama covers the two are the same to well under a metre.
    ///
    /// - Parameters:
    ///   - coordinate: The position to test.
    ///   - polygon: The polygon to test it against, holes included.
    ///   - ignoringBoundary: When true, a point sitting exactly on an edge counts as
    ///     outside. Neighbouring regions that share a border are the reason this exists: with the
    ///     default, a point on the border is inside *both*.
    public static func contains(
        _ coordinate: Coordinate,
        in polygon: Polygon,
        ignoringBoundary: Bool = false
    ) -> Bool {
        guard let exterior = polygon.exterior,
              inRing(coordinate, exterior, ignoringBoundary: ignoringBoundary)
        else { return false }

        // A point on the *inside* of a hole's edge is on the polygon's boundary too, so the
        // boundary rule passes straight through rather than being inverted with the containment.
        return !polygon.holes.contains { inRing(coordinate, $0, ignoringBoundary: !ignoringBoundary) }
    }

    /// Whether a coordinate falls inside any of a set of polygons.
    public static func contains(
        _ coordinate: Coordinate,
        in multiPolygon: MultiPolygon,
        ignoringBoundary: Bool = false
    ) -> Bool {
        multiPolygon.polygons.contains { contains(coordinate, in: $0, ignoringBoundary: ignoringBoundary) }
    }

    /// Whether a coordinate falls inside a geometry's area. Points and lines contain nothing.
    public static func contains(
        _ coordinate: Coordinate,
        in geometry: Geometry,
        ignoringBoundary: Bool = false
    ) -> Bool {
        switch geometry {
        case .polygon(let polygon):
            return contains(coordinate, in: polygon, ignoringBoundary: ignoringBoundary)
        case .multiPolygon(let multiPolygon):
            return contains(coordinate, in: multiPolygon, ignoringBoundary: ignoringBoundary)
        case .geometryCollection(let geometries):
            return geometries.contains { contains(coordinate, in: $0, ignoringBoundary: ignoringBoundary) }
        case .point, .multiPoint, .lineString, .multiLineString:
            return false
        }
    }

    /// The crossing-number test against one ring.
    private static func inRing(
        _ coordinate: Coordinate,
        _ ring: LinearRing,
        ignoringBoundary: Bool
    ) -> Bool {
        let points = ring.open
        guard points.count >= 3 else { return false }

        let x = coordinate.longitude
        let y = coordinate.latitude
        var isInside = false
        var previous = points.count - 1

        for index in points.indices {
            let xi = points[index].longitude
            let yi = points[index].latitude
            let xj = points[previous].longitude
            let yj = points[previous].latitude
            previous = index

            // Collinear with the edge and within its span, so exactly on the boundary. Answered
            // before the crossing test, because a ray through a vertex is ambiguous and the point
            // being *on* the edge is not.
            let onEdge = (y * (xi - xj) + yi * (xj - x) + yj * (x - xi)) == 0
                && (xi - x) * (xj - x) <= 0
                && (yi - y) * (yj - y) <= 0
            if onEdge { return !ignoringBoundary }

            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                isInside.toggle()
            }
        }
        return isInside
    }
}

// MARK: - Point on line

extension Turf {
    /// Where a line comes closest to a coordinate.
    public struct NearestPoint: Sendable, Hashable {
        /// The closest point on the line.
        public var coordinate: Coordinate
        /// The index of the segment it sits on, counting from the line's first position.
        public var segmentIndex: Int
        /// How far along the line it is, in metres.
        public var locationMeters: Double
        /// How far it is from the coordinate that was asked about, in metres.
        public var distanceMeters: Double
    }

    /// The point on a line closest to the given coordinate.
    public static func nearestPoint(on line: LineString, to coordinate: Coordinate) -> NearestPoint? {
        nearestPoint(on: line.coordinates, to: coordinate)
    }

    /// The point on a run of positions closest to the given coordinate.
    ///
    /// Each segment is projected into a local east/north frame about the query point before the
    /// perpendicular is dropped, which is a flat-earth step taken deliberately: the exact
    /// great-circle version needs three-dimensional unit vectors per segment, and over the few
    /// kilometres a diorama spans the two agree to well under a millimetre. The distance that comes
    /// back is measured on the sphere regardless, so it is comparable with everything else here.
    public static func nearestPoint(
        on coordinates: [Coordinate],
        to coordinate: Coordinate
    ) -> NearestPoint? {
        guard let first = coordinates.first else { return nil }
        guard coordinates.count >= 2 else {
            return NearestPoint(
                coordinate: first,
                segmentIndex: 0,
                locationMeters: 0,
                distanceMeters: distance(from: coordinate, to: first)
            )
        }

        let metersPerDegree = .pi / 180 * earthRadiusMeters
        let eastScale = cos(coordinate.latitudeRadians) * metersPerDegree

        func project(_ point: Coordinate) -> SIMD2<Double> {
            SIMD2(
                normalizedLongitude(point.longitude - coordinate.longitude) * eastScale,
                (point.latitude - coordinate.latitude) * metersPerDegree
            )
        }

        func unproject(_ point: SIMD2<Double>) -> Coordinate {
            Coordinate(
                longitude: normalizedLongitude(coordinate.longitude + point.x / eastScale),
                latitude: coordinate.latitude + point.y / metersPerDegree
            )
        }

        var best: NearestPoint?
        var travelled = 0.0

        for index in 0..<(coordinates.count - 1) {
            let start = coordinates[index]
            let end = coordinates[index + 1]
            let segmentLength = distance(from: start, to: end)

            let a = project(start)
            let b = project(end)
            let span = b - a
            let lengthSquared = simd_length_squared(span)
            let t = lengthSquared > 0 ? simd_clamp(simd_dot(-a, span) / lengthSquared, 0, 1) : 0
            let closest = unproject(a + span * t)

            let candidate = NearestPoint(
                coordinate: closest,
                segmentIndex: index,
                locationMeters: travelled + segmentLength * t,
                distanceMeters: distance(from: coordinate, to: closest)
            )
            if best == nil || candidate.distanceMeters < best!.distanceMeters {
                best = candidate
            }
            travelled += segmentLength
        }
        return best
    }

    /// Whether a coordinate lies on a line, within the given tolerance in metres.
    ///
    /// Turf's `booleanPointOnLine` tests for exact collinearity in degrees. That is the right answer
    /// for synthetic data and useless for measured data, where a coordinate that came from the line
    /// misses it in the last decimal place — so this asks a distance question instead, and the
    /// tolerance is stated in the same metres everything else here uses.
    public static func isPoint(
        _ coordinate: Coordinate,
        on line: LineString,
        toleranceMeters: Double = 0.01
    ) -> Bool {
        guard let nearest = nearestPoint(on: line.coordinates, to: coordinate) else { return false }
        return nearest.distanceMeters <= toleranceMeters
    }
}
