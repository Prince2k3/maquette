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

    /// Creates a bounding volume from parsed JSON, applying the accumulated tile transform and ECEF conversion.
    ///
    /// Per the 3D Tiles spec, bounding volumes are defined in the tile's local coordinate system.
    /// The accumulated `transform` converts them to ECEF (tileset coordinate system).
    /// Region volumes are in geographic coordinates and are not affected by the transform.
    public init?(from json: BoundingVolumeJSON, transform: simd_double4x4, ecefConverter: ECEFConverter) {
        if let region = json.region, region.count >= 6 {
            // Region is in geographic coordinates — not affected by tile transform
            self = .region(
                west: region[0], south: region[1],
                east: region[2], north: region[3],
                minHeight: region[4], maxHeight: region[5]
            )
        } else if let box = json.box, box.count >= 12 {
            // Transform tile-local center to ECEF using accumulated transform (Double precision)
            let localCenter = SIMD4<Double>(box[0], box[1], box[2], 1.0)
            let ecefCenter4 = transform * localCenter
            let ecefCenter = SIMD3<Double>(ecefCenter4.x, ecefCenter4.y, ecefCenter4.z)
            let enuCenter = ecefConverter.ecefToLocal(ecefCenter)

            // Half-axes are rotated into the local frame rather than kept at their raw
            // orientation. Magnitudes alone are enough for a sphere approximation, but not for
            // measuring the distance to the box itself, which is what level-of-detail needs.
            let rotation = simd_double3x3(
                SIMD3<Double>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3<Double>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3<Double>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )
            let toLocal = ecefConverter.ecefToENU * rotation

            func localAxis(_ a: Double, _ b: Double, _ c: Double) -> SIMD3<Float> {
                let enu = toLocal * SIMD3<Double>(a, b, c)
                // ENU (East, North, Up) → RealityKit (East, Up, -North), matching `ecefToLocal`.
                return SIMD3<Float>(Float(enu.x), Float(enu.z), Float(-enu.y))
            }

            self = .box(
                center: enuCenter,
                halfAxes: simd_float3x3(
                    localAxis(box[3], box[4], box[5]),
                    localAxis(box[6], box[7], box[8]),
                    localAxis(box[9], box[10], box[11])
                )
            )
        } else if let sphere = json.sphere, sphere.count >= 4 {
            // Transform tile-local center to ECEF
            let localCenter = SIMD4<Double>(sphere[0], sphere[1], sphere[2], 1.0)
            let ecefCenter4 = transform * localCenter
            let ecefCenter = SIMD3<Double>(ecefCenter4.x, ecefCenter4.y, ecefCenter4.z)
            let enuCenter = ecefConverter.ecefToLocal(ecefCenter)

            self = .sphere(center: enuCenter, radius: Float(sphere[3]))
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

        case .box, .sphere:
            // The diorama's footprint is a vertical column about the local origin, not a sphere —
            // the same shape `BoundaryPrism` clips to, which has vertical sides and no caps. So
            // this measures horizontal distance rather than the full 3D distance.
            //
            // Testing the 3D distance instead ties how much terrain survives to how far the ground
            // sits above the ellipsoid, because the origin is at ellipsoid height zero. At sea
            // level the vertical term is nil and the two agree, which is why it went unnoticed; in
            // the mountains it culls everything. Half Dome's summit is ~2,700 m up, so a 1,400 m
            // chunk there rejected every tile it was made of, dead centre included.
            guard horizontalDistanceFromOrigin() < Float(radiusMeters) else { return false }

            // The column still has to end. Extended without limit it does not stop at bedrock — it
            // runs through the planet and out the far side, where the antipode's east and north
            // components are both nil and its horizontal distance from the origin is therefore
            // zero. Every antipodal tile passes the test above, and a tileset rooted at the whole
            // Earth has some.
            //
            // They are not harmless. Their footprint lands inside the outline, so `BoundaryPrism`
            // keeps them too, and they arrive as geometry one Earth diameter below the table —
            // which is then the lowest thing loaded, so the tray and the vertical datum both
            // anchor to it and the real terrain ends up kilometres above the chunk.
            let vertical = verticalRangeFromOrigin()
            return vertical.upperBound >= -Self.terrainElevationBound
                && vertical.lowerBound <= Self.terrainElevationBound
        }
    }

    /// How far above and below the ellipsoid surface terrain can plausibly sit, in meters.
    ///
    /// Deliberately loose. It exists to separate this planet's surface from its far side, not to
    /// trim tiles to the chunk — that is the outline's job — so it clears Everest by a wide margin
    /// rather than sitting anywhere near real terrain.
    static let terrainElevationBound: Float = 12_000

    /// The vertical span this volume covers, measured from the local origin. Up is positive.
    private func verticalRangeFromOrigin() -> ClosedRange<Float> {
        switch self {
        case .region:
            // Region volumes carry no local-space position; the lat/lon test above handles them.
            return 0...0

        case .sphere(let center, let radius):
            return (center.y - radius)...(center.y + radius)

        case .box(let center, let halfAxes):
            // As with the footprint, summing each axis's vertical reach bounds the true extent from
            // outside, so the error is towards keeping a tile rather than discarding one.
            var reach: Float = 0
            for index in 0..<3 {
                reach += abs(halfAxes[index].y)
            }

            return (center.y - reach)...(center.y + reach)
        }
    }

    /// Horizontal distance from the local origin to the nearest point of this volume, ignoring
    /// height. Zero when the origin lies within the volume's footprint.
    private func horizontalDistanceFromOrigin() -> Float {
        switch self {
        case .region:
            return 0

        case .sphere(let center, let radius):
            // A sphere projects to a disc of the same radius, so this is exact.
            return max(simd_length(SIMD2(center.x, center.z)) - radius, 0)

        case .box(let center, let halfAxes):
            // An oriented box projects to a hexagon in general. Its bounding rectangle stands in:
            // summing each axis's horizontal reach can only overstate the footprint, so the error
            // is towards keeping a tile that could have been culled rather than discarding one that
            // belongs.
            var extent = SIMD2<Float>.zero
            for index in 0..<3 {
                let axis = halfAxes[index]
                extent += SIMD2(abs(axis.x), abs(axis.z))
            }

            let offset = SIMD2(abs(center.x), abs(center.z))
            return simd_length(simd_max(offset - extent, .zero))
        }
    }

    /// Computes the screen-space geometric error for LOD decisions.
    public func screenSpaceError(
        geometricError: Double,
        cameraPosition: SIMD3<Float>,
        screenHeight: Float,
        fov: Float
    ) -> Double {
        // The spec measures error against the distance to the volume, not to its middle. Using the
        // centre overstates how far away a large tile is — its near face can be right in front of
        // the camera — so the error comes out too small and the tile is never refined.
        let distance = max(Double(self.distance(to: cameraPosition)), 0.001)
        let halfFovTan = tan(Double(fov) / 2.0)

        return (geometricError * Double(screenHeight)) / (distance * 2.0 * halfFovTan)
    }

    /// Distance from a point to the nearest point of this volume. Zero when the point is inside.
    public func distance(to point: SIMD3<Float>) -> Float {
        switch self {
        case .region:
            // Region volumes carry no local-space position, so the origin stands in for them.
            return simd_length(point)

        case .sphere(let center, let radius):
            return max(simd_length(point - center) - radius, 0)

        case .box(let center, let halfAxes):
            // Project into the box's own frame, clamp to its extent, and measure what is left
            // over. The axes are orthogonal, so projecting onto each normalized axis is enough.
            let offset = point - center
            var outside = SIMD3<Float>.zero

            for index in 0..<3 {
                let axis = halfAxes[index]
                let length = simd_length(axis)
                guard length > .ulpOfOne else { continue }
                let projection = simd_dot(offset, axis / length)
                outside[index] = max(abs(projection) - length, 0)
            }

            return simd_length(outside)
        }
    }
}
