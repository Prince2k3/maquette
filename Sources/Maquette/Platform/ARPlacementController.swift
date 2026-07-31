#if os(iOS)
import Foundation
import RealityKit

/// Runs the spatial-tracking session AR placement needs, and owns the plane anchor the diorama
/// lands on.
///
/// This is the modern, RealityView-native AR path — `SpatialTrackingSession` plus an
/// `AnchorEntity(.plane(...))` — not `ARView` and not an `ARKitSession`: no UIKit, no per-frame
/// delegate, and the same `RealityView` the virtual camera uses. The session is what entitles the
/// anchor to real plane detection; without one running, a plane-anchored entity never resolves.
@MainActor
@Observable
final class ARPlacementController {
    /// Whether placement is currently active.
    private(set) var isActive = false

    /// The anchor the diorama parents to while placing: the first horizontal, table-like surface
    /// the device finds, at least large enough to hold a tabletop model.
    private(set) var planeAnchor: AnchorEntity?

    private var session: SpatialTrackingSession?

    /// Starts plane tracking and creates a fresh anchor for the diorama to ride.
    func activate() async {
        guard !isActive else { return }
        let session = SpatialTrackingSession()
        let configuration = SpatialTrackingSession.Configuration(tracking: [.plane])
        // An unavailable capability (no camera permission, no LiDAR, the simulator) comes back
        // here rather than throwing; the anchor then simply never resolves, which the caller can
        // see and the user reads as "still looking for a surface".
        _ = await session.run(configuration)
        self.session = session

        let anchor = AnchorEntity(
            .plane(.horizontal, classification: .table, minimumBounds: SIMD2<Float>(0.3, 0.3))
        )
        anchor.name = "DioramaPlacementAnchor"
        self.planeAnchor = anchor
        isActive = true
    }

    /// Stops tracking and drops the anchor. The caller re-parents the diorama first.
    func deactivate() async {
        await session?.stop()
        session = nil
        planeAnchor?.removeFromParent()
        planeAnchor = nil
        isActive = false
    }
}
#endif
