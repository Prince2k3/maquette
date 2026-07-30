import Foundation

// MARK: - Extent

extension Turf {
    /// The extent of a set of positions.
    public static func boundingBox(of coordinates: some Sequence<Coordinate>) -> GeographicBounds? {
        GeographicBounds(enclosing: coordinates)
    }

    /// The extent of a geometry.
    public static func boundingBox(of geometry: Geometry) -> GeographicBounds? {
        GeographicBounds(enclosing: geometry.coordinates)
    }

    /// The extent of a feature's geometry, measured rather than taken from its declared `bbox`.
    public static func boundingBox(of feature: Feature) -> GeographicBounds? {
        feature.geometry.flatMap(boundingBox(of:))
    }

    /// The extent of every feature in a collection.
    public static func boundingBox(of collection: FeatureCollection) -> GeographicBounds? {
        GeographicBounds(enclosing: collection.features.flatMap { $0.geometry?.coordinates ?? [] })
    }
}

// MARK: - Centres

extension Turf {
    /// The middle of a geometry's extent — the centre of the box, not of the mass.
    ///
    /// This is Turf's `center`, and it is the one to use for "point the camera at this": it does
    /// not drift towards whichever end of the shape happens to carry more vertices.
    public static func center(of geometry: Geometry) -> Coordinate? {
        boundingBox(of: geometry)?.center
    }

    /// The mean of a geometry's positions.
    ///
    /// This is Turf's `centroid`, a vertex average rather than an area centroid — so a shape with a
    /// finely-detailed coastline and a straight inland edge pulls towards the coast. That is worth
    /// knowing before using it to place a label.
    public static func centroid(of geometry: Geometry) -> Coordinate? {
        let coordinates = geometry.coordinates
        guard !coordinates.isEmpty else { return nil }
        var longitude = 0.0
        var latitude = 0.0
        for coordinate in coordinates {
            longitude += coordinate.longitude
            latitude += coordinate.latitude
        }
        let count = Double(coordinates.count)
        return Coordinate(longitude: longitude / count, latitude: latitude / count)
    }
}

// MARK: - Length

extension Turf {
    /// The length of a run of positions in metres, summed segment by segment.
    public static func length(of coordinates: [Coordinate]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        var total = 0.0
        for index in 0..<(coordinates.count - 1) {
            total += distance(from: coordinates[index], to: coordinates[index + 1])
        }
        return total
    }

    /// The length of a line in metres.
    public static func length(of line: LineString) -> Double {
        length(of: line.coordinates)
    }

    /// The total length of every line and ring in a geometry, in metres.
    ///
    /// Points contribute nothing, and a polygon contributes its perimeter — which is what Turf's
    /// `length` does, and is why a polygon's *area* is a separate question.
    public static func length(of geometry: Geometry) -> Double {
        switch geometry {
        case .point, .multiPoint:
            return 0
        case .lineString(let line):
            return length(of: line.coordinates)
        case .multiLineString(let lines):
            return lines.lineStrings.reduce(0) { $0 + length(of: $1.coordinates) }
        case .polygon(let polygon):
            return polygon.rings.reduce(0) { $0 + length(of: $1.coordinates) }
        case .multiPolygon(let multiPolygon):
            return multiPolygon.polygons.reduce(0) { total, polygon in
                total + polygon.rings.reduce(0) { $0 + length(of: $1.coordinates) }
            }
        case .geometryCollection(let geometries):
            return geometries.reduce(0) { $0 + length(of: $1) }
        }
    }

    /// The point the given distance along a line.
    ///
    /// Distances past either end clamp to that end rather than extrapolating, so a route preview
    /// asked for a position beyond the route stops at its destination instead of flying off it.
    public static func along(_ line: LineString, meters: Double) -> Coordinate? {
        along(line.coordinates, meters: meters)
    }

    /// The point the given distance along a run of positions.
    public static func along(_ coordinates: [Coordinate], meters: Double) -> Coordinate? {
        guard let first = coordinates.first else { return nil }
        guard meters > 0 else { return first }

        var travelled = 0.0
        for index in 0..<max(coordinates.count - 1, 0) {
            let start = coordinates[index]
            let end = coordinates[index + 1]
            let segment = distance(from: start, to: end)
            if travelled + segment >= meters {
                guard segment > 0 else { return start }
                return destination(
                    from: start,
                    meters: meters - travelled,
                    bearing: bearing(from: start, to: end)
                )
            }
            travelled += segment
        }
        return coordinates.last
    }
}

// MARK: - Area

extension Turf {
    /// The area of a polygon in square metres, holes removed.
    public static func area(of polygon: Polygon) -> Double {
        guard let exterior = polygon.exterior else { return 0 }
        return polygon.holes.reduce(abs(ringArea(exterior))) { $0 - abs(ringArea($1)) }
    }

    /// The area of a set of polygons in square metres.
    public static func area(of multiPolygon: MultiPolygon) -> Double {
        multiPolygon.polygons.reduce(0) { $0 + area(of: $1) }
    }

    /// The area a geometry encloses in square metres. Points and lines enclose nothing.
    public static func area(of geometry: Geometry) -> Double {
        switch geometry {
        case .polygon(let polygon):
            return area(of: polygon)
        case .multiPolygon(let multiPolygon):
            return area(of: multiPolygon)
        case .geometryCollection(let geometries):
            return geometries.reduce(0) { $0 + area(of: $1) }
        case .point, .multiPoint, .lineString, .multiLineString:
            return 0
        }
    }

    /// The signed area a ring encloses on the sphere, in square metres.
    ///
    /// This is the spherical-excess integral Turf uses, not the planar shoelace sum: degrees of
    /// longitude are not a fixed distance, so a shoelace over lon/lat understates a polygon in
    /// Alaska by more than half. Positive for one winding and negative for the other, which is why
    /// every caller above takes the magnitude.
    static func ringArea(_ ring: LinearRing) -> Double {
        let points = ring.open
        guard points.count > 2 else { return 0 }

        var total = 0.0
        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count]
            let next = points[(index + 1) % points.count]
            total += (next.longitudeRadians - previous.longitudeRadians)
                * sin(points[index].latitudeRadians)
        }
        return total * earthRadiusMeters * earthRadiusMeters / 2
    }
}
