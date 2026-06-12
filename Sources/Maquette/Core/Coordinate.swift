import CoreLocation
import Foundation
import simd

/// Lightweight helpers for working with geographic coordinates in the context of map tiles and diorama positioning.
public struct Coordinate: Sendable, Hashable, Codable {
    /// Latitude in degrees.
    public var latitude: Double
    /// Longitude in degrees.
    public var longitude: Double

    /// Creates a coordinate from latitude and longitude in degrees.
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Creates a `Coordinate` from a `CLLocationCoordinate2D`.
    public init(_ clCoordinate: CLLocationCoordinate2D) {
        self.latitude = clCoordinate.latitude
        self.longitude = clCoordinate.longitude
    }

    /// Converts to a `CLLocationCoordinate2D`.
    public var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Latitude in radians.
    public var latitudeRadians: Double {
        latitude * .pi / 180.0
    }

    /// Longitude in radians.
    public var longitudeRadians: Double {
        longitude * .pi / 180.0
    }

    /// Approximate distance in meters to another coordinate using the Haversine formula.
    public func distance(to other: Coordinate) -> Double {
        let earthRadius = 6_371_000.0

        let dLat = (other.latitude - latitude) * .pi / 180.0
        let dLon = (other.longitude - longitude) * .pi / 180.0

        let lat1 = latitudeRadians
        let lat2 = other.latitudeRadians

        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return earthRadius * c
    }

    /// Returns a new coordinate offset by the given distance in meters along north and east axes.
    public func offset(northMeters: Double, eastMeters: Double) -> Coordinate {
        let earthRadius = 6_371_000.0
        let dLat = northMeters / earthRadius * (180.0 / .pi)
        let dLon = eastMeters / (earthRadius * cos(latitudeRadians)) * (180.0 / .pi)
        return Coordinate(latitude: latitude + dLat, longitude: longitude + dLon)
    }
}

extension Coordinate: CustomStringConvertible {
    public var description: String {
        String(format: "(%0.6f, %0.6f)", latitude, longitude)
    }
}

// MARK: - ECEF Converter

/// Converts between ECEF (Earth-Centered, Earth-Fixed) and local ENU (East-North-Up) coordinates.
///
/// Used to transform OGC 3D Tiles geometry (which uses ECEF) into local diorama coordinates.
public struct ECEFConverter: Sendable {
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
