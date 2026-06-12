#if !os(visionOS)
import Foundation

/// Shared route animation logic for iOS and macOS platform views.
///
/// Centralizes the frame-advance and playback state change handling that
/// both `IOSDioramaView` and `MacOSDioramaView` use identically.
@MainActor
enum RouteAnimationHelper {

    /// Advances the route animation by one frame.
    ///
    /// Updates the route preview controller's progress, drives the route entity's
    /// visual progress, and updates the camera controller's follow mode.
    ///
    /// - Parameters:
    ///   - date: The current frame timestamp from `TimelineView`.
    ///   - controller: The route preview playback controller.
    ///   - routeEntity: The route preview entity to update, if present.
    ///   - cameraController: The orbit camera controller for follow mode updates.
    ///   - lastAnimationDate: Mutable reference to the last frame timestamp for delta calculation.
    static func advanceAnimation(
        at date: Date,
        controller: RoutePreviewController,
        routeEntity: RoutePreviewEntity?,
        cameraController: CameraController,
        lastAnimationDate: inout Date?
    ) {
        controller.update(at: date)
        guard let routeEntity else { return }

        routeEntity.updateProgress(controller.progress)
        let position = routeEntity.currentPosition(at: controller.progress)
        let direction = routeEntity.routeDirection(at: controller.progress)

        let deltaTime: Float
        if let lastDate = lastAnimationDate {
            deltaTime = min(Float(date.timeIntervalSince(lastDate)), 0.1)
        } else {
            deltaTime = 1.0 / 60.0
        }
        lastAnimationDate = date

        cameraController.updateRouteFollowMode(
            markerPosition: position,
            routeDirection: direction,
            deltaTime: deltaTime
        )
    }

    /// Handles route preview playback state changes.
    ///
    /// Enters camera follow mode on play, begins exit animation on stop,
    /// and clears animation timing on pause or removal.
    ///
    /// - Parameters:
    ///   - newState: The new playback state, or `nil` if the controller was removed.
    ///   - cameraController: The orbit camera controller.
    ///   - routeEntity: The route preview entity, if present.
    ///   - lastAnimationDate: Mutable reference to reset on state changes.
    static func handlePlaybackStateChange(
        _ newState: RoutePreviewPlaybackState?,
        cameraController: CameraController,
        routeEntity: RoutePreviewEntity?,
        lastAnimationDate: inout Date?
    ) {
        switch newState {
        case .playing:
            lastAnimationDate = nil
            if cameraController.followMode == .orbit {
                if let routeEntity {
                    let initialDirection = routeEntity.routeDirection(at: 0)
                    cameraController.enterRouteFollowMode(
                        routePoints: routeEntity.routePoints,
                        initialDirection: initialDirection
                    )
                }
            }
        case .stopped:
            lastAnimationDate = nil
            cameraController.beginExitAnimation()
        case .paused:
            lastAnimationDate = nil
        case nil:
            lastAnimationDate = nil
            cameraController.exitFollowMode()
        }
    }
}
#endif
