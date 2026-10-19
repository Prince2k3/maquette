import CoreLocation
import Foundation
import simd

/// Converts between ECEF (Earth-Centered, Earth-Fixed) and local ENU (East-North-Up) coordinates.
///
/// Used to transform OGC 3D Tiles geometry (which uses ECEF) into local diorama coordinates, and by
/// ``EllipsoidProjection`` to put a geographic coordinate in the same frame that geometry arrived
/// in. Both go through the WGS84 ellipsoid, which is what 3D Tiles are positioned against — a
/// spherical approximation here would place a pin next to the building it names rather than on it.
struct ECEFConverter: Sendable {
    // WGS84 constants
    private static let semiMajorAxis: Double = 6_378_137.0
    private static let eccentricitySquared: Double = 0.00669437999014

    /// Origin latitude in radians.
    public let originLatRad: Double
    /// Origin longitude in radians.
    public let originLonRad: Double
    /// Origin altitude in meters.
    public let originAltitude: Double
    /// Origin point in ECEF coordinates.
    public let originECEF: SIMD3<Double>
    /// Rotation matrix from ECEF to local ENU frame.
    public let ecefToENU: simd_double3x3

    /// Creates an ECEF converter centered on the given geographic coordinate.
    public init(origin: CLLocationCoordinate2D, altitude: Double = 0) {
        self.originLatRad = origin.latitude * .pi / 180.0
        self.originLonRad = origin.longitude * .pi / 180.0
        self.originAltitude = altitude

        let sinLat = sin(originLatRad)
        let cosLat = cos(originLatRad)
        let sinLon = sin(originLonRad)
        let cosLon = cos(originLonRad)

        // Prime vertical radius of curvature
        let n = Self.semiMajorAxis / sqrt(1.0 - Self.eccentricitySquared * sinLat * sinLat)

        // Origin in ECEF
        self.originECEF = SIMD3<Double>(
            (n + altitude) * cosLat * cosLon,
            (n + altitude) * cosLat * sinLon,
            (n * (1.0 - Self.eccentricitySquared) + altitude) * sinLat
        )

        // ENU rotation matrix columns (each row of the matrix)
        let east  = SIMD3<Double>(-sinLon,            cosLon,           0)
        let north = SIMD3<Double>(-sinLat * cosLon,  -sinLat * sinLon,  cosLat)
        let up    = SIMD3<Double>( cosLat * cosLon,   cosLat * sinLon,  sinLat)

        self.ecefToENU = simd_double3x3(rows: [east, north, up])
    }

    /// Converts a geographic coordinate to ECEF, in metres.
    ///
    /// The inverse of the geodetic conversion the origin itself goes through, so a coordinate equal
    /// to the origin comes back as `originECEF` exactly.
    public func ecef(for coordinate: Coordinate) -> SIMD3<Double> {
        let latRad = coordinate.latitudeRadians
        let lonRad = coordinate.longitudeRadians
        let altitude = coordinate.altitude ?? 0

        let sinLat = sin(latRad)
        let cosLat = cos(latRad)
        let n = Self.semiMajorAxis / sqrt(1.0 - Self.eccentricitySquared * sinLat * sinLat)

        return SIMD3<Double>(
            (n + altitude) * cosLat * cos(lonRad),
            (n + altitude) * cosLat * sin(lonRad),
            (n * (1.0 - Self.eccentricitySquared) + altitude) * sinLat
        )
    }

    /// Converts a geographic coordinate straight to local RealityKit coordinates, in metres.
    ///
    /// This is the direction ``EllipsoidProjection`` needs: geometry arrives ECEF and is converted
    /// *in*, while placement starts from a coordinate and has to reach the same frame.
    public func local(for coordinate: Coordinate) -> SIMD3<Float> {
        ecefToLocal(ecef(for: coordinate))
    }

    /// The near-side WGS84 coordinate at a horizontal point in the local frame.
    /// Intersects the frame's vertical ray with the ellipsoid, rather than approximating it
    /// with a sphere. Points beyond the local horizon have no near-side intersection.
    func coordinate(atHorizontalPoint point: SIMD2<Double>) -> Coordinate? {
        let rotation = ecefToENU.transpose
        let start = originECEF + rotation * SIMD3(point.x, -point.y, 0)
        let direction = rotation * SIMD3<Double>(0, 0, 1)
        let a2 = Self.semiMajorAxis * Self.semiMajorAxis
        let b2 = a2 * (1 - Self.eccentricitySquared)
        let weights = SIMD3<Double>(1 / a2, 1 / a2, 1 / b2)
        let a = simd_dot(direction * direction, weights)
        let b = 2 * simd_dot(start * direction, weights)
        let c = simd_dot(start * start, weights) - 1
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return nil }
        let vertical = (-b + sqrt(discriminant)) / (2 * a)
        let ecef = start + direction * vertical
        let longitude = atan2(ecef.y, ecef.x)
        let latitude = atan2(ecef.z, hypot(ecef.x, ecef.y) * (1 - Self.eccentricitySquared))
        return Coordinate(longitude: longitude * 180 / .pi, latitude: latitude * 180 / .pi)
    }

    /// Converts an ECEF position to local ENU coordinates (meters from diorama center).
    public func ecefToLocal(_ ecef: SIMD3<Double>) -> SIMD3<Float> {
        let delta = ecef - originECEF
        let enu = ecefToENU * delta
        // Map ENU (East, North, Up) to RealityKit (X, Y, Z) = (East, Up, -North)
        return SIMD3<Float>(Float(enu.x), Float(enu.z), Float(-enu.y))
    }

    /// Converts a 4x4 ECEF transform matrix to local RealityKit coordinates.
    ///
    /// Accepts `simd_double4x4` to preserve full precision of ECEF positions
    /// (which are ~6,000,000 m and would lose significant precision as Float32).
    public func ecefTransformToLocal(_ transform: simd_double4x4) -> simd_float4x4 {
        // Extract translation in Double precision and convert to local
        let ecefPosition = SIMD3<Double>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let localPosition = ecefToLocal(ecefPosition)

        // Extract 3x3 rotation/scale in Double precision
        let rotation3x3 = simd_double3x3(
            SIMD3<Double>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Double>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Double>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )

        // Rotate basis vectors from ECEF into ENU space
        let enuRotation = ecefToENU * rotation3x3

        // Apply ENU → RealityKit axis permutation to each column:
        // ENU (East, North, Up) → RK (East, Up, -North)
        // For each column vector (e, n, u) → (e, u, -n)
        let c0 = enuRotation.columns.0
        let c1 = enuRotation.columns.1
        let c2 = enuRotation.columns.2

        return simd_float4x4(
            SIMD4<Float>(Float(c0.x), Float(c0.z), Float(-c0.y), 0),
            SIMD4<Float>(Float(c1.x), Float(c1.z), Float(-c1.y), 0),
            SIMD4<Float>(Float(c2.x), Float(c2.z), Float(-c2.y), 0),
            SIMD4<Float>(localPosition, 1)
        )
    }
}
