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
final class CameraController {
    /// Horizontal orbit angle in radians.
    public var azimuth: Float = 0

    /// Vertical orbit angle in radians (clamped to prevent flipping).
    public var elevation: Float = DioramaSceneRig.restingElevation

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

    /// The camera's world-space position derived from spherical coordinates.
    public var cameraPosition: SIMD3<Float> {
        let x = distance * cos(elevation) * sin(azimuth)
        let y = distance * sin(elevation)
        let z = distance * cos(elevation) * cos(azimuth)
        return target + SIMD3<Float>(x, y, z)
    }

    /// Computes the camera transform from current spherical coordinates.
    public var cameraTransform: Transform {
        let position = cameraPosition

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

    /// Converts a screen-space drag into a terrain pan delta in diorama meters.
    ///
    /// The result makes the ground track the finger: dragging right slides terrain to the right
    /// regardless of which way the camera is facing. Because the chunk shows the terrain sampled at
    /// `position + offset`, moving the ground one way means moving the offset the other, which is
    /// why the result is negated.
    ///
    /// - Parameters:
    ///   - dragDeltaX: Horizontal drag in points, positive to the right.
    ///   - dragDeltaY: Vertical drag in points, positive downward.
    ///   - viewHeight: Height of the view in points.
    ///   - entityScale: Scale applied to the diorama entity.
    ///   - fieldOfView: Vertical camera field of view in radians.
    public func terrainPanDelta(
        dragDeltaX: Float,
        dragDeltaY: Float,
        viewHeight: Float,
        entityScale: Float,
        fieldOfView: Float = 60 * .pi / 180
    ) -> SIMD2<Float> {
        guard viewHeight > 0, entityScale > 0 else { return .zero }

        // World height visible at the orbit target, divided across the view's points.
        let visibleHeight = 2 * distance * tan(fieldOfView / 2)
        let metersPerPoint = visibleHeight / viewHeight / entityScale

        return -groundDrag(deltaX: dragDeltaX, deltaY: dragDeltaY) * metersPerPoint
    }

    /// Which way the ground under the pointer moves for a screen drag, in the diorama's horizontal
    /// plane and in the drag's own units — `x` eastward, `y` southward.
    ///
    /// The camera's azimuth is the whole of it: the diorama's axes are fixed and the *screen's* are
    /// not, so a rightward drag means +X only while the camera is looking down −Z. Anything reading
    /// a drag as ground has to go through this, and the globe is the case where forgetting to is
    /// hardest to spot — the chunk visibly slides the wrong way, whereas a globe simply spins to
    /// somewhere other than the place that was aimed at, which still looks like a globe spinning.
    ///
    /// Scale is the caller's, because what a screen point is worth is not the camera's business
    /// alone: the chunk measures it at the orbit target and the globe at its own near surface.
    public func groundDrag(deltaX: Float, deltaY: Float) -> SIMD2<Float> {
        let screenRight = SIMD2<Float>(cos(azimuth), -sin(azimuth))
        let screenDown = SIMD2<Float>(sin(azimuth), cos(azimuth))
        return screenRight * deltaX + screenDown * deltaY
    }

    /// Updates the target offset based on pan deltas.
    public func pan(deltaX: Float, deltaY: Float) {
        let right = SIMD3<Float>(cos(azimuth), 0, -sin(azimuth))
        let forward = SIMD3<Float>(sin(azimuth), 0, cos(azimuth))

        target += right * deltaX * panSensitivity
        target += forward * deltaY * panSensitivity
    }

    // MARK: - Follow Mode (Route Preview)

    /// Camera follow mode.
    public enum FollowMode: Sendable {
        /// Standard orbit mode — user controls camera freely.
        case orbit
        /// Camera follows a route preview with phase-driven behavior.
        case following
    }

    /// Sub-phases within `.following` mode for route preview.
    public enum RouteFollowPhase: Sendable {
        /// Camera animating toward overview position to show the entire route.
        case overview
        /// Animating from overview to behind-marker view.
        case transitioning
        /// Following marker position with bearing locked.
        case cruising
        /// Rotating bearing because marker is leaving the camera's field of view.
        case repositioning
        /// Animating camera back to its pre-follow position.
        case exiting
    }

    /// Current camera mode.
    public var followMode: FollowMode = .orbit

    /// Current phase within follow mode.
    public private(set) var routeFollowPhase: RouteFollowPhase = .overview

    /// The target position to follow when in follow mode.
    var followTarget: SIMD3<Float>?

    // MARK: - Route Follow Internal State

    /// The locked bearing held during cruising (radians).
    private var lockedAzimuth: Float = 0

    /// The target bearing during repositioning (radians).
    private var repositionTargetAzimuth: Float = 0

    /// Time elapsed in the current phase (seconds).
    private var phaseElapsed: Float = 0

    /// The overview center point computed from route bounds.
    private var overviewCenter: SIMD3<Float> = .zero

    /// The overview distance computed from route bounds.
    private var overviewDistance: Float = 1.0

    /// The target follow distance after transition.
    private var followDistance: Float = 0.5

    /// Route points stored for terrain clearance checks during follow mode.
    private var followRoutePoints: [SIMD3<Float>] = []

    /// Cooldown timer preventing rapid repositioning triggers (seconds remaining).
    private var repositionCooldown: Float = 0

    /// Saved camera state for restoration on exit.
    private var savedDistance: Float?
    private var savedElevation: Float?
    private var savedTarget: SIMD3<Float>?
    private var savedAzimuth: Float?

    // MARK: - Route Follow Constants

    /// Duration to hold the overview before transitioning (seconds).
    private let overviewDuration: Float = 2.0

    /// Duration of the transition from overview to behind-marker (seconds).
    private let transitionDuration: Float = 1.5

    /// Half of the PerspectiveCamera's 60° FOV, in radians.
    private let fovHalfAngle: Float = 30.0 * .pi / 180.0

    /// Angle threshold for triggering repositioning (radians). Set inside the FOV edge.
    private let visibilityThreshold: Float = 25.0 * .pi / 180.0

    /// Smoothing factor for camera position lerp during cruising/repositioning.
    private let followSmoothing: Float = 0.05

    /// Smoothing factor for azimuth lerp during repositioning.
    private let repositionSmoothing: Float = 0.03

    /// Maximum angular change per frame during repositioning (radians).
    /// Prevents jarring fast rotation when the delta is large.
    private let maxAngularStep: Float = 0.015

    /// Cooldown after repositioning completes before it can re-trigger (seconds).
    private let repositionCooldownDuration: Float = 0.8

    /// Multiplier for vertical (Y-axis) target tracking relative to horizontal.
    private let verticalTrackingMultiplier: Float = 3.0

    /// Factor for adjusting camera elevation based on marker height relative to target.
    private let pitchTrackingFactor: Float = 0.5

    /// Duration of the exit animation back to the original camera position (seconds).
    private let exitDuration: Float = 1.5

    /// Baseline elevation during cruising/repositioning (radians).
    private let followElevation: Float = .pi / 5

    /// Vertical clearance above terrain obstacles (meters in diorama space).
    private let terrainClearanceMargin: Float = 0.02

    /// Search radius for sampling terrain height near the camera-to-marker midpoint.
    private let terrainSampleRadius: Float = 0.15

    // MARK: - Enter / Exit

    /// Enters route follow mode, starting with a smooth animation to the route overview.
    ///
    /// The camera animates from its current position to an overview that frames the entire
    /// route, then transitions to behind the marker for playback.
    ///
    /// - Parameters:
    ///   - routePoints: All 3D positions along the route for bounding box computation.
    ///   - initialDirection: The route direction at the start for initial behind-marker azimuth.
    public func enterRouteFollowMode(
        routePoints: [SIMD3<Float>],
        initialDirection: SIMD2<Float>
    ) {
        // Only save if not already saved (preserves original state across play/stop/play)
        if savedTarget == nil {
            savedDistance = distance
            savedElevation = elevation
            savedTarget = target
            savedAzimuth = azimuth
        }

        // Store route points for terrain clearance checks
        followRoutePoints = routePoints

        // Compute bounding box and overview camera parameters
        let (center, overviewDist) = computeOverviewParameters(routePoints: routePoints)
        overviewCenter = center
        overviewDistance = overviewDist

        // Store a closer follow distance for after transition
        followDistance = max(overviewDist * 0.4, minDistance)

        // Compute the behind-start azimuth (camera behind the marker, looking forward)
        lockedAzimuth = atan2(-initialDirection.x, -initialDirection.y)

        // Begin overview phase — camera animates toward overview position (no snap)
        followMode = .following
        routeFollowPhase = .overview
        phaseElapsed = 0
        repositionCooldown = 0
    }

    /// Begins a smooth exit animation back to the pre-follow camera position.
    ///
    /// The camera animates from its current position back to where it was before
    /// follow mode started. When complete, `followMode` returns to `.orbit`.
    public func beginExitAnimation() {
        guard case .following = followMode else { return }
        routeFollowPhase = .exiting
        phaseElapsed = 0
    }

    /// Immediately exits follow mode and restores the camera (no animation).
    ///
    /// Use `beginExitAnimation()` for a smooth transition. This method is for
    /// immediate cleanup (e.g., controller removed from environment).
    public func exitFollowMode() {
        followMode = .orbit
        routeFollowPhase = .overview
        followTarget = nil
        phaseElapsed = 0

        // Restore saved camera state
        if let d = savedDistance { distance = d }
        if let e = savedElevation { elevation = e }
        if let t = savedTarget { target = t }
        if let a = savedAzimuth { azimuth = a }

        savedDistance = nil
        savedElevation = nil
        savedTarget = nil
        savedAzimuth = nil
        followRoutePoints = []
        repositionCooldown = 0
    }

    // MARK: - Per-Frame Update

    /// Updates the camera each frame during route follow mode.
    ///
    /// Called by the platform view's `advanceAnimation` method. Drives the phase
    /// state machine: overview → transitioning → cruising ↔ repositioning.
    ///
    /// - Parameters:
    ///   - markerPosition: Current 3D position of the route marker.
    ///   - routeDirection: Normalized XZ direction the route is heading.
    ///   - deltaTime: Time elapsed since last frame (seconds).
    public func updateRouteFollowMode(
        markerPosition: SIMD3<Float>,
        routeDirection: SIMD2<Float>,
        deltaTime: Float
    ) {
        guard case .following = followMode else { return }

        phaseElapsed += deltaTime

        switch routeFollowPhase {
        case .overview:
            // Smoothly animate camera toward overview position
            target = target + (overviewCenter - target) * 0.08
            distance = distance + (overviewDistance - distance) * 0.08
            elevation = elevation + (.pi / 5 - elevation) * 0.08

            if phaseElapsed >= overviewDuration {
                routeFollowPhase = .transitioning
                phaseElapsed = 0
            }

        case .transitioning:
            let t = min(phaseElapsed / transitionDuration, 1.0)
            let easedT = smoothstep(t)

            // Interpolate target from overview center toward marker position
            let blendedTarget = overviewCenter + (markerPosition - overviewCenter) * easedT
            target = target + (blendedTarget - target) * 0.1

            // Interpolate azimuth toward behind-marker bearing
            lerpAzimuthToward(lockedAzimuth, factor: easedT * 0.08)

            // Interpolate distance from overview to follow distance
            let targetDist = overviewDistance + (followDistance - overviewDistance) * easedT
            distance = distance + (targetDist - distance) * 0.05

            if t >= 1.0 {
                lockedAzimuth = azimuth
                routeFollowPhase = .cruising
            }

        case .cruising:
            // Follow marker position smoothly in XZ
            target.x += (markerPosition.x - target.x) * followSmoothing
            target.z += (markerPosition.z - target.z) * followSmoothing
            // Track marker Y more aggressively to maintain vertical visibility
            target.y += (markerPosition.y - target.y) * (followSmoothing * verticalTrackingMultiplier)

            // Compute target elevation: combine terrain clearance and pitch tracking
            let targetElevation = computeTargetElevation(markerPosition: markerPosition)
            elevation += (targetElevation - elevation) * followSmoothing

            // Decrement repositioning cooldown
            repositionCooldown = max(0, repositionCooldown - deltaTime)

            // Check if the marker is leaving the camera's field of view
            if repositionCooldown <= 0,
               let newAzimuth = checkVisibilityNeedsRepositioning(
                   markerPosition: markerPosition,
                   routeDirection: routeDirection
               ) {
                repositionTargetAzimuth = newAzimuth
                routeFollowPhase = .repositioning
                phaseElapsed = 0
            }

        case .repositioning:
            // Follow marker position smoothly in XZ
            target.x += (markerPosition.x - target.x) * followSmoothing
            target.z += (markerPosition.z - target.z) * followSmoothing
            // Track marker Y more aggressively
            target.y += (markerPosition.y - target.y) * (followSmoothing * verticalTrackingMultiplier)

            // Compute target elevation: combine terrain clearance and pitch tracking
            let targetElevationR = computeTargetElevation(markerPosition: markerPosition)
            elevation += (targetElevationR - elevation) * followSmoothing

            // Smoothly rotate toward the new bearing with capped angular velocity
            lerpAzimuthToward(repositionTargetAzimuth, factor: repositionSmoothing, maxStep: maxAngularStep)

            // Check convergence
            var delta = repositionTargetAzimuth - azimuth
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            if abs(delta) < 0.05 {
                lockedAzimuth = azimuth
                routeFollowPhase = .cruising
                repositionCooldown = repositionCooldownDuration
            }

            // Update reposition target as marker moves
            if let updatedAzimuth = checkVisibilityNeedsRepositioning(
                markerPosition: markerPosition,
                routeDirection: routeDirection
            ) {
                repositionTargetAzimuth = updatedAzimuth
            }

        case .exiting:
            guard let savedT = savedTarget, let savedD = savedDistance,
                  let savedE = savedElevation, let savedA = savedAzimuth else {
                completeExit()
                return
            }

            let smoothing: Float = 0.06
            target = target + (savedT - target) * smoothing
            distance = distance + (savedD - distance) * smoothing
            elevation = elevation + (savedE - elevation) * smoothing
            lerpAzimuthToward(savedA, factor: smoothing)

            if phaseElapsed >= exitDuration {
                target = savedT
                distance = savedD
                elevation = savedE
                azimuth = savedA
                completeExit()
            }
        }
    }

    // MARK: - Private Helpers

    /// Completes the exit animation and returns to orbit mode.
    private func completeExit() {
        followMode = .orbit
        routeFollowPhase = .overview
        followTarget = nil
        followRoutePoints = []
        phaseElapsed = 0
        repositionCooldown = 0
        savedDistance = nil
        savedElevation = nil
        savedTarget = nil
        savedAzimuth = nil
    }

    /// Computes camera distance and center to frame the entire route.
    private func computeOverviewParameters(routePoints: [SIMD3<Float>]) -> (center: SIMD3<Float>, distance: Float) {
        guard !routePoints.isEmpty else {
            return (target, distance)
        }

        var minP = routePoints[0]
        var maxP = routePoints[0]
        for p in routePoints {
            minP = SIMD3<Float>(min(minP.x, p.x), min(minP.y, p.y), min(minP.z, p.z))
            maxP = SIMD3<Float>(max(maxP.x, p.x), max(maxP.y, p.y), max(maxP.z, p.z))
        }

        let center = (minP + maxP) * 0.5
        let extentXZ = max(maxP.x - minP.x, maxP.z - minP.z)

        // Distance to fit XZ extent in FOV with 1.3x padding
        let halfExtent = extentXZ * 0.5 * 1.3
        let overviewDist = halfExtent / tan(fovHalfAngle)

        return (center, max(min(overviewDist, maxDistance), minDistance))
    }

    /// Checks whether the marker is about to leave the camera's horizontal view.
    ///
    /// Returns the azimuth that would point the camera at the marker (minimum rotation)
    /// when the marker drifts out of view. For the preemptive case (route heading toward
    /// camera), returns the behind-marker azimuth to get ahead of the turn.
    ///
    /// - Returns: A new target azimuth if repositioning is needed, or `nil` if the bearing is fine.
    private func checkVisibilityNeedsRepositioning(
        markerPosition: SIMD3<Float>,
        routeDirection: SIMD2<Float>
    ) -> Float? {
        // Camera position in XZ plane (from spherical coords)
        let cosElev = cos(elevation)
        let cameraX = target.x + distance * cosElev * sin(azimuth)
        let cameraZ = target.z + distance * cosElev * cos(azimuth)

        // Vector from camera to marker in XZ
        let toMarkerX = markerPosition.x - cameraX
        let toMarkerZ = markerPosition.z - cameraZ
        let toMarkerLength = sqrt(toMarkerX * toMarkerX + toMarkerZ * toMarkerZ)

        guard toMarkerLength > 0.0001 else { return nil }

        // Camera forward direction in XZ (camera looks from position toward target)
        let forwardX = -sin(azimuth)
        let forwardZ = -cos(azimuth)

        // Angle between camera forward and camera-to-marker vector
        let dot = (forwardX * toMarkerX + forwardZ * toMarkerZ) / toMarkerLength
        let angleToMarker = acos(max(-1, min(1, dot)))

        // Reposition if the marker is outside the visibility threshold.
        // Target: point camera directly at the marker (minimum rotation).
        if angleToMarker > visibilityThreshold {
            return atan2(-toMarkerX, -toMarkerZ)
        }

        // Preemptive reposition if route is heading very directly toward the camera.
        // Target: get behind the marker to anticipate the turn.
        let routeTowardCamera = -(routeDirection.x * forwardX + routeDirection.y * forwardZ)
        if routeTowardCamera > 0.7 {
            return atan2(-routeDirection.x, -routeDirection.y)
        }

        return nil
    }

    /// Computes the minimum camera elevation needed to clear terrain between camera and marker.
    ///
    /// Samples route point heights near the camera-to-marker line of sight.
    /// If terrain along that corridor rises above the direct line between camera and marker,
    /// returns a higher elevation angle to see over it.
    ///
    /// - Parameter markerPosition: Current 3D position of the route marker.
    /// - Returns: Minimum elevation in radians needed for clearance, or the baseline if no obstruction.
    private func computeMinElevationForClearance(markerPosition: SIMD3<Float>) -> Float {
        guard !followRoutePoints.isEmpty else { return followElevation }

        // Camera ground position in XZ from spherical coordinates
        let cameraX = target.x + distance * cos(elevation) * sin(azimuth)
        let cameraZ = target.z + distance * cos(elevation) * cos(azimuth)
        let cameraY = target.y + distance * sin(elevation)

        // Midpoint between camera and marker in XZ
        let midX = (cameraX + markerPosition.x) * 0.5
        let midZ = (cameraZ + markerPosition.z) * 0.5

        // Find the maximum terrain height among route points near the corridor
        let sampleRadiusSq = terrainSampleRadius * terrainSampleRadius
        var maxTerrainY: Float = -Float.greatestFiniteMagnitude

        for point in followRoutePoints {
            let dx = point.x - midX
            let dz = point.z - midZ
            let distSq = dx * dx + dz * dz
            if distSq <= sampleRadiusSq {
                maxTerrainY = max(maxTerrainY, point.y)
            }
        }

        // No nearby route points — no obstruction
        guard maxTerrainY > -Float.greatestFiniteMagnitude else {
            return followElevation
        }

        // Check if terrain is above the camera-to-marker line of sight
        let lineOfSightYAtMid = (cameraY + markerPosition.y) * 0.5
        let heightDiff = maxTerrainY + terrainClearanceMargin - lineOfSightYAtMid

        guard heightDiff > 0 else {
            return followElevation
        }

        // Compute the elevation angle needed: asin((heightAboveTarget + clearance) / distance)
        let neededRise = maxTerrainY + terrainClearanceMargin - target.y
        let ratio = neededRise / max(distance, 0.01)
        let clampedRatio = max(-1, min(1, ratio))
        let neededElevation = asin(clampedRatio)

        return max(followElevation, min(neededElevation, maxElevation))
    }

    /// Computes the target camera elevation combining terrain clearance and pitch tracking.
    ///
    /// Terrain clearance raises the camera to see over obstacles. Pitch tracking adjusts
    /// the elevation so the camera's viewing angle keeps the marker centered vertically.
    private func computeTargetElevation(markerPosition: SIMD3<Float>) -> Float {
        // Terrain clearance: ensures camera can see over obstacles
        let clearanceElev = computeMinElevationForClearance(markerPosition: markerPosition)

        // Pitch tracking: adjust based on marker height relative to camera target.
        // Positive height diff (marker above target) → lower elevation to look upward.
        // Negative height diff (marker below target) → raise elevation to look downward.
        let heightDiff = markerPosition.y - target.y
        let pitchElev = followElevation - heightDiff * pitchTrackingFactor

        // Take the maximum of both — terrain clearance always wins
        return max(minElevation, min(maxElevation, max(clearanceElev, pitchElev)))
    }

    /// Smoothly interpolates azimuth toward a target, handling angular wrapping.
    ///
    /// - Parameters:
    ///   - targetAzimuth: The target angle in radians.
    ///   - factor: Interpolation factor per frame (0–1).
    ///   - maxStep: Maximum angular change per frame in radians. Defaults to unlimited.
    private func lerpAzimuthToward(_ targetAzimuth: Float, factor: Float, maxStep: Float = .greatestFiniteMagnitude) {
        var delta = targetAzimuth - azimuth
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        let step = delta * factor
        azimuth += max(-maxStep, min(maxStep, step))
    }

    /// Smooth Hermite interpolation (ease-in-out).
    private func smoothstep(_ t: Float) -> Float {
        let clamped = max(0, min(1, t))
        return clamped * clamped * (3 - 2 * clamped)
    }
}
#endif
