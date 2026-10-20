import Foundation
import simd

enum OverlayProjectionDomain: Sendable { case mercator, ellipsoid }

/// Geographic construction always delegates placement to the active diorama projection.
struct OverlayGeographicGeometry: Sendable {
    private let projection: any DioramaProjection
    private let referenceLongitude: Double
    private let domain: OverlayProjectionDomain
    init(projection: any DioramaProjection, referenceLongitude: Double, domain: OverlayProjectionDomain) throws {
        guard referenceLongitude.isFinite else { throw OverlayGeometryError.nonFiniteInput }
        self.projection = projection; self.referenceLongitude = referenceLongitude; self.domain = domain
    }

    /// A rolling anchor can live in an unwrapped world copy. Derive the reference from that
    /// anchor, not a normalized region longitude, and include the current ground pan.
    init(projection: TerrainProjection) throws {
        let center = projection.anchor.coordinate(forDioramaX: Double(projection.panOffset.x), z: Double(projection.panOffset.y))
        try self.init(projection: projection, referenceLongitude: center.longitude, domain: .mercator)
    }

    init(projection: EllipsoidProjection) throws {
        try self.init(projection: projection, referenceLongitude: projection.converter.originLonRad * 180 / .pi, domain: .ellipsoid)
    }

    func project(_ coordinates: [Coordinate], limits: OverlayGeometryLimits = .init()) throws -> [OverlayVertex] {
        guard coordinates.count <= limits.maxInputVertices else { throw OverlayGeometryError.budgetExceeded }
        var reference = referenceLongitude
        return try coordinates.map { coordinate in
            let vertex = try projected(coordinate, relativeTo: reference)
            reference = try unwrappedLongitude(coordinate.longitude, relativeTo: reference)
            return vertex
        }
    }

    private func unwrappedLongitude(_ longitude: Double, relativeTo reference: Double) throws -> Double {
        let delta = longitude - reference
        guard delta.isFinite else { throw OverlayGeometryError.nonFiniteInput }
        return reference + delta.remainder(dividingBy: 360)
    }

    private func projected(_ coordinate: Coordinate, uv: SIMD2<Double> = .zero, relativeTo reference: Double? = nil) throws -> OverlayVertex {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite, (coordinate.altitude ?? 0).isFinite else {
            throw OverlayGeometryError.nonFiniteInput
        }
        let latitudeLimit = domain == .mercator ? 85.0511287798066 : 90.0
        guard abs(coordinate.latitude) <= latitudeLimit else { throw OverlayGeometryError.invalidProjection }
        var local = coordinate
        local.longitude = try unwrappedLongitude(coordinate.longitude, relativeTo: reference ?? referenceLongitude)
        let point = projection.point(for: local)
        let vertex = OverlayVertex(point: SIMD2<Double>(point), uv: uv, altitude: coordinate.altitude ?? 0)
        guard vertex.isFinite else { throw OverlayGeometryError.nonFiniteInput }
        return vertex
    }

    /// Adaptive angular subdivision measured in diorama-space error. Source radius remains analytic.
    /// Quarter/midpoint checks constrain nonlinear projection as well as the circle's chord error.
    func circle(center: Coordinate, radius: Double, maximumError: Double,
                limits: OverlayGeometryLimits = .init()) throws -> [OverlayVertex] {
        guard radius.isFinite, radius > 0, radius < .pi * Turf.earthRadiusMeters,
              maximumError.isFinite, maximumError > 0 else { throw OverlayGeometryError.invalidRadius }
        var work = try OverlayWork(limits)
        _ = try projected(center)
        let circleReference = try unwrappedLongitude(center.longitude, relativeTo: referenceLongitude)
        func at(_ bearing: Double) throws -> OverlayVertex {
            try projected(Turf.destination(from: center, meters: radius, bearing: bearing), relativeTo: circleReference)
        }
        struct Arc { var start: Double; var end: Double; var a: OverlayVertex; var b: OverlayVertex }
        var stack: [Arc] = []
        for i in (0..<8).reversed() {
            stack.append(Arc(start: Double(i) * 45, end: Double(i + 1) * 45,
                             a: try at(Double(i) * 45), b: try at(Double(i + 1) * 45)))
        }
        var result: [OverlayVertex] = []
        while let arc = stack.popLast() {
            try work.spend(3)
            let middle = arc.start + (arc.end - arc.start) / 2
            let midpoint = try at(middle)
            var error = simd_distance(midpoint.point, (arc.a.point + arc.b.point) / 2)
            for fraction in [0.25, 0.75] {
                let sample = try at(arc.start + (arc.end - arc.start) * fraction)
                error = max(error, simd_distance(sample.point, arc.a.point + (arc.b.point - arc.a.point) * fraction))
            }
            if error <= maximumError {
                result.append(arc.a)
            } else {
                guard middle > arc.start, middle < arc.end else { throw OverlayGeometryError.budgetExceeded }
                stack.append(Arc(start: middle, end: arc.end, a: midpoint, b: arc.b))
                stack.append(Arc(start: arc.start, end: middle, a: arc.a, b: midpoint))
            }
            guard result.count + stack.count <= limits.maxCircleSegments,
                  result.count + stack.count <= limits.maxInputVertices else { throw OverlayGeometryError.budgetExceeded }
        }
        return result
    }

    /// North-up UVs use v=0 at the north edge. Clipping interpolates the original UVs, never
    /// renormalizes them to the visible portion. Wrapped longitude bounds use one local world copy.
    func image(bounds: GeographicBounds) throws -> [OverlayVertex] {
        guard [bounds.west, bounds.east, bounds.south, bounds.north].allSatisfy(\.isFinite) else {
            throw OverlayGeometryError.nonFiniteInput
        }
        let width = bounds.east >= bounds.west ? bounds.east - bounds.west : bounds.east + 360 - bounds.west
        guard width > 0, width < 180, bounds.north > bounds.south else { throw OverlayGeometryError.invalidProjection }
        let west = referenceLongitude + (bounds.west - referenceLongitude).remainder(dividingBy: 360)
        // Keep both corners in the same copy even if an individual nearest-copy choice would differ.
        let center = west + width / 2
        let local = try OverlayGeographicGeometry(projection: projection, referenceLongitude: center, domain: domain)
        return try [
            local.projected(.init(latitude: bounds.north, longitude: west), uv: .init(0, 0)),
            local.projected(.init(latitude: bounds.north, longitude: west + width), uv: .init(1, 0)),
            local.projected(.init(latitude: bounds.south, longitude: west + width), uv: .init(1, 1)),
            local.projected(.init(latitude: bounds.south, longitude: west), uv: .init(0, 1))
        ]
    }
}
