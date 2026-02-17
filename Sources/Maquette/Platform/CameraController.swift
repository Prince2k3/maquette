#if !os(visionOS)
import Foundation
import RealityKit
import simd

/// Orbit camera controller for iOS and macOS.
///
/// Manages a virtual camera that orbits around the diorama center using spherical coordinates.
/// Driven by gesture handlers in the platform views.
@Observable
@MainActor
public final class CameraController {
    /// Horizontal orbit angle in radians.
    public var azimuth: Float = 0

    /// Vertical orbit angle in radians (clamped to prevent flipping).
    public var elevation: Float = .pi / 4

    /// Distance from the target point in meters.
    public var distance: Float = 1.0

    /// The point the camera is looking at.
    public var target: SIMD3<Float> = .zero

    /// Minimum elevation angle in radians.
    public var minElevation: Float = 10.0 * .pi / 180.0

    /// Maximum elevation angle in radians.
    public var maxElevation: Float = 80.0 * .pi / 180.0

    /// Minimum zoom distance.
    public var minDistance: Float = 0.3

    /// Maximum zoom distance.
    public var maxDistance: Float = 10.0

    /// Rotation sensitivity multiplier.
    public var rotationSensitivity: Float = 0.005

    /// Zoom sensitivity multiplier.
    public var zoomSensitivity: Float = 0.01

    /// Pan sensitivity multiplier.
    public var panSensitivity: Float = 0.002

    /// Creates a camera controller with default settings.
    public init() {}

    /// Creates a camera controller with initial parameters.
    public init(elevation: Float, distance: Float) {
        self.elevation = elevation
        self.distance = distance
    }

    /// Computes the camera transform from current spherical coordinates.
    public var cameraTransform: Transform {
        let x = distance * cos(elevation) * sin(azimuth)
        let y = distance * sin(elevation)
        let z = distance * cos(elevation) * cos(azimuth)

        let position = target + SIMD3<Float>(x, y, z)

        // Look-at: compute rotation from camera position to target
        let forward = simd_normalize(target - position)
        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = simd_cross(forward, worldUp)
        let rightLen = simd_length(right)
        if rightLen < 1e-6 {
            // Camera is looking straight up or down; pick an arbitrary right vector
            right = SIMD3<Float>(1, 0, 0)
        } else {
            right /= rightLen
        }
        let up = simd_cross(right, forward)

        let rotationMatrix = simd_float3x3(columns: (right, up, -forward))
        let quaternion = simd_quatf(rotationMatrix)

        var transform = Transform()
        transform.translation = position
        transform.rotation = quaternion
        return transform
    }

    /// Updates azimuth and elevation based on drag deltas.
    public func rotate(deltaX: Float, deltaY: Float) {
        azimuth += deltaX * rotationSensitivity
        elevation -= deltaY * rotationSensitivity
        elevation = min(max(elevation, minElevation), maxElevation)
    }

    /// Updates orbit distance based on zoom delta.
    public func zoom(delta: Float) {
        distance -= delta * zoomSensitivity
        distance = min(max(distance, minDistance), maxDistance)
    }

    /// Updates the target offset based on pan deltas.
    public func pan(deltaX: Float, deltaY: Float) {
        let right = SIMD3<Float>(cos(azimuth), 0, -sin(azimuth))
        let forward = SIMD3<Float>(sin(azimuth), 0, cos(azimuth))

        target += right * deltaX * panSensitivity
        target += forward * deltaY * panSensitivity
    }
}
#endif
