import CoreLocation
import Foundation
import simd

/// Bounding volume types used in 3D Tiles for visibility and LOD decisions.
public enum BoundingVolume: Sendable {
    /// Region bounding volume with geographic extents in radians and height in meters.
    case region(west: Double, south: Double, east: Double, north: Double, minHeight: Double, maxHeight: Double)
    /// Oriented bounding box with center and half-axes.
    case box(center: SIMD3<Float>, halfAxes: simd_float3x3)
    /// Bounding sphere with center and radius.
    case sphere(center: SIMD3<Float>, radius: Float)

    /// Creates a bounding volume from parsed JSON, applying a transform and ECEF conversion.
    public init?(from json: BoundingVolumeJSON, transform: simd_float4x4, ecefConverter: ECEFConverter) {
        if let region = json.region, region.count >= 6 {
            self = .region(
                west: region[0], south: region[1],
                east: region[2], north: region[3],
                minHeight: region[4], maxHeight: region[5]
            )
        } else if let box = json.box, box.count >= 12 {
            let center = SIMD3<Double>(box[0], box[1], box[2])
            let localCenter = ecefConverter.ecefToLocal(center)

            let xAxis = SIMD3<Float>(Float(box[3]), Float(box[4]), Float(box[5]))
            let yAxis = SIMD3<Float>(Float(box[6]), Float(box[7]), Float(box[8]))
            let zAxis = SIMD3<Float>(Float(box[9]), Float(box[10]), Float(box[11]))

            self = .box(center: localCenter, halfAxes: simd_float3x3(xAxis, yAxis, zAxis))
        } else if let sphere = json.sphere, sphere.count >= 4 {
            let center = SIMD3<Double>(sphere[0], sphere[1], sphere[2])
            let localCenter = ecefConverter.ecefToLocal(center)

            self = .sphere(center: localCenter, radius: Float(sphere[3]))
        } else {
            return nil
        }
    }

    /// Creates a bounding volume directly from parsed JSON without coordinate conversion.
    public init?(from json: BoundingVolumeJSON) {
        if let region = json.region, region.count >= 6 {
            self = .region(
                west: region[0], south: region[1],
                east: region[2], north: region[3],
                minHeight: region[4], maxHeight: region[5]
            )
        } else if let box = json.box, box.count >= 12 {
            let center = SIMD3<Float>(Float(box[0]), Float(box[1]), Float(box[2]))
            let xAxis = SIMD3<Float>(Float(box[3]), Float(box[4]), Float(box[5]))
            let yAxis = SIMD3<Float>(Float(box[6]), Float(box[7]), Float(box[8]))
            let zAxis = SIMD3<Float>(Float(box[9]), Float(box[10]), Float(box[11]))

            self = .box(center: center, halfAxes: simd_float3x3(xAxis, yAxis, zAxis))
        } else if let sphere = json.sphere, sphere.count >= 4 {
            let center = SIMD3<Float>(Float(sphere[0]), Float(sphere[1]), Float(sphere[2]))
            self = .sphere(center: center, radius: Float(sphere[3]))
        } else {
            return nil
        }
    }

    /// Tests if this volume intersects with the diorama's geographic region.
    public func intersects(center: CLLocationCoordinate2D, radiusMeters: Double) -> Bool {
        switch self {
        case .region(let west, let south, let east, let north, _, _):
            let centerLatRad = center.latitude * .pi / 180.0
            let centerLonRad = center.longitude * .pi / 180.0
            let radiusRad = radiusMeters / 6_371_000.0

            let latOverlap = south <= centerLatRad + radiusRad && north >= centerLatRad - radiusRad
            let lonOverlap = west <= centerLonRad + radiusRad && east >= centerLonRad - radiusRad
            return latOverlap && lonOverlap

        case .box(let boxCenter, let halfAxes):
            let extent = simd_length(halfAxes.columns.0) + simd_length(halfAxes.columns.1) + simd_length(halfAxes.columns.2)
            let dist = simd_length(boxCenter)
            return dist - extent < Float(radiusMeters)

        case .sphere(let sphereCenter, let radius):
            let dist = simd_length(sphereCenter)
            return dist - radius < Float(radiusMeters)
        }
    }

    /// Computes the screen-space geometric error for LOD decisions.
    public func screenSpaceError(
        geometricError: Double,
        cameraPosition: SIMD3<Float>,
        screenHeight: Float,
        fov: Float
    ) -> Double {
        let center: SIMD3<Float> = switch self {
        case .region: .zero
        case .box(let c, _): c
        case .sphere(let c, _): c
        }

        let distance = max(Double(simd_length(cameraPosition - center)), 0.001)
        let halfFovTan = tan(Double(fov) / 2.0)

        return (geometricError * Double(screenHeight)) / (distance * 2.0 * halfFovTan)
    }
}
