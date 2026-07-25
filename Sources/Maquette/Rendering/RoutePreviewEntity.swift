import Foundation
import RealityKit
import SwiftUI

/// Entity that composes the visual elements of a route preview animation.
///
/// Contains three child entities:
/// - `dimmedRoute`: Full route path rendered in a translucent color (static).
/// - `highlightedRoute`: Growing prefix of the route in a bright color (mesh updated each frame).
/// - `marker`: A sphere that moves along the route path.
///
/// ```
/// RoutePreviewEntity (root)
/// ├── dimmedRoute (ModelEntity — full route, low opacity)
/// ├── highlightedRoute (ModelEntity — prefix route, bright)
/// └── marker (ModelEntity — sphere at current position)
/// ```
@MainActor
public class RoutePreviewEntity: Entity {

    /// The full dimmed route entity.
    private(set) var dimmedRoute: ModelEntity?

    /// The growing highlighted route entity.
    private(set) var highlightedRoute: ModelEntity?

    /// The animated marker sphere entity.
    private(set) var marker: ModelEntity?

    /// The precomputed 3D positions along the route, in diorama space.
    let routePoints: [SIMD3<Float>]

    /// Cumulative distances along the route at each point index, normalized to [0, 1].
    let normalizedDistances: [Float]

    /// The route preview style.
    let style: RoutePreviewStyle

    /// Y offset to prevent z-fighting with the terrain.
    let yOffset: Float

    /// The last segment index used for mesh generation, to avoid redundant rebuilds.
    private var lastHighlightedSegmentIndex: Int = -1

    /// Creates a route preview entity from precomputed 3D positions.
    ///
    /// - Parameters:
    ///   - routePoints: 3D positions along the route in diorama space.
    ///   - style: Visual style configuration.
    ///   - physicalDiameter: Diorama physical diameter for proportional sizing.
    ///   - yOffset: Vertical offset above terrain surface.
    public init(
        routePoints: [SIMD3<Float>],
        style: RoutePreviewStyle,
        physicalDiameter: Float,
        yOffset: Float
    ) throws {
        self.routePoints = routePoints
        self.style = style
        self.yOffset = yOffset

        // Precompute normalized cumulative distances
        var distances: [Float] = [0]
        var totalLength: Float = 0
        for i in 1..<routePoints.count {
            totalLength += simd_distance(routePoints[i - 1], routePoints[i])
            distances.append(totalLength)
        }
        self.normalizedDistances = totalLength > 0
            ? distances.map { $0 / totalLength }
            : distances

        super.init()
        self.name = "RoutePreview"

        // Create the dimmed full route (static)
        let dimmedMesh = try PolylineMeshGenerator.generateMesh(
            from: routePoints,
            width: style.lineWidth,
            yOffset: yOffset
        )
        let dimmedMaterial = DioramaMaterials.unlitMaterial(color: style.dimmedColor)
        let dimmed = ModelEntity(mesh: dimmedMesh, materials: [dimmedMaterial])
        dimmed.name = "RoutePreview_Dimmed"
        self.dimmedRoute = dimmed
        addChild(dimmed)

        // Create the highlighted route (initially a minimal 2-point prefix)
        let initialPoints = Array(routePoints.prefix(2))
        let highlightMesh = try PolylineMeshGenerator.generateMesh(
            from: initialPoints,
            width: style.lineWidth * 1.2,
            yOffset: yOffset + 0.0001
        )
        let highlightMaterial = DioramaMaterials.unlitMaterial(color: style.highlightColor)
        let highlighted = ModelEntity(mesh: highlightMesh, materials: [highlightMaterial])
        highlighted.name = "RoutePreview_Highlighted"
        self.highlightedRoute = highlighted
        addChild(highlighted)

        // Create the marker sphere
        let markerRadius = style.markerRadius ?? physicalDiameter * 0.008
        let markerMesh = MeshResource.generateSphere(radius: markerRadius)
        let markerMaterial = DioramaMaterials.unlitMaterial(color: style.markerColor)
        let markerEntity = ModelEntity(mesh: markerMesh, materials: [markerMaterial])
        markerEntity.name = "RoutePreview_Marker"
        markerEntity.position = routePoints[0]
        self.marker = markerEntity
        addChild(markerEntity)
    }

    @MainActor
    required init() {
        self.routePoints = []
        self.normalizedDistances = []
        self.style = RoutePreviewStyle()
        self.yOffset = 0
        super.init()
    }

    // MARK: - Frame Update

    /// Updates the route preview entities to reflect the current progress.
    ///
    /// Repositions the marker sphere and regenerates the highlighted route prefix mesh.
    ///
    /// - Parameter progress: Normalized progress along the route, from 0.0 to 1.0.
    public func updateProgress(_ progress: Float) {
        let clampedProgress = max(0, min(1, progress))

        // Compute the current position and segment index
        let (position, segmentIndex) = interpolatedPosition(at: clampedProgress)

        // Update marker position (cheap — every frame)
        marker?.position = position

        // Only regenerate the highlighted route mesh when the segment index changes
        guard segmentIndex != lastHighlightedSegmentIndex else { return }
        lastHighlightedSegmentIndex = segmentIndex

        // Update highlighted route mesh: prefix up to current position
        let prefixPointCount = segmentIndex + 1
        guard prefixPointCount >= 1 else { return }

        var prefixPoints = Array(routePoints.prefix(prefixPointCount + 1))

        // Replace the last point with the interpolated current position
        if prefixPoints.count >= 2 {
            prefixPoints[prefixPoints.count - 1] = position
        } else if prefixPoints.count == 1 {
            prefixPoints.append(position)
        }

        guard prefixPoints.count >= 2 else { return }

        guard let newMesh = try? PolylineMeshGenerator.generateMesh(
            from: prefixPoints,
            width: style.lineWidth * 1.2,
            yOffset: yOffset + 0.0001
        ) else { return }

        // Replace the mesh contents
        try? highlightedRoute?.model?.mesh.replace(with: newMesh.contents)
    }

    /// Returns the current interpolated position at the given progress.
    ///
    /// - Parameter progress: Normalized progress along the route.
    /// - Returns: The interpolated 3D position in diorama space.
    public func currentPosition(at progress: Float) -> SIMD3<Float> {
        interpolatedPosition(at: max(0, min(1, progress))).position
    }

    /// Returns the route direction (in the XZ plane) at the given progress.
    ///
    /// Used by the camera controller to set bearing during follow mode.
    ///
    /// - Parameter progress: Normalized progress along the route.
    /// - Returns: A normalized 2D direction vector (x, z) in diorama space.
    public func routeDirection(at progress: Float) -> SIMD2<Float> {
        let (_, segmentIndex) = interpolatedPosition(at: max(0, min(1, progress)))
        let nextIndex = min(segmentIndex + 1, routePoints.count - 1)
        let currentPoint = routePoints[max(0, segmentIndex)]
        let nextPoint = routePoints[nextIndex]

        let dx = nextPoint.x - currentPoint.x
        let dz = nextPoint.z - currentPoint.z
        let length = sqrt(dx * dx + dz * dz)
        guard length > 0.0001 else {
            return SIMD2<Float>(0, 1)
        }
        return SIMD2<Float>(dx / length, dz / length)
    }

    // MARK: - Private

    /// Interpolates a 3D position along the route at the given normalized progress.
    private func interpolatedPosition(at progress: Float) -> (position: SIMD3<Float>, segmentIndex: Int) {
        guard routePoints.count >= 2 else {
            return (routePoints.first ?? .zero, 0)
        }

        let clampedProgress = max(0, min(1, progress))

        // Find the segment containing this progress value
        var segmentIndex = 0
        for i in 1..<normalizedDistances.count {
            if normalizedDistances[i] >= clampedProgress {
                segmentIndex = i - 1
                break
            }
            segmentIndex = i - 1
        }

        // Edge case: at the very end
        if segmentIndex >= routePoints.count - 1 {
            return (routePoints.last!, routePoints.count - 2)
        }

        // Interpolate within the segment
        let segStart = normalizedDistances[segmentIndex]
        let segEnd = normalizedDistances[segmentIndex + 1]
        let segLength = segEnd - segStart

        let t: Float = segLength > 0.0001
            ? (clampedProgress - segStart) / segLength
            : 0

        let p0 = routePoints[segmentIndex]
        let p1 = routePoints[segmentIndex + 1]
        let position = p0 + (p1 - p0) * t

        return (position, segmentIndex)
    }
}
