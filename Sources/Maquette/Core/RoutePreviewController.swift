import Foundation
import os

/// Playback state for the route preview animation.
public enum RoutePreviewPlaybackState: Sendable, Hashable {
    /// Animation has not started or has been reset.
    case stopped
    /// Animation is actively playing.
    case playing
    /// Animation is paused at the current progress.
    case paused
}

/// Controls the playback of a route preview animation.
///
/// Holds the animation state (play/pause/stop, progress, speed) and converts
/// wall-clock time into a normalized `progress` value from 0 (route start) to 1 (route end).
///
/// Create an instance as `@State` in your view and pass it to a `DioramaView`
/// via the `.routePreviewController(_:)` modifier.
///
/// ```swift
/// @State private var controller = RoutePreviewController()
///
/// DioramaView(configuration: config) {
///     DioramaRoutePreview(coordinates: coords)
/// }
/// .routePreviewController(controller)
///
/// Button("Play") { controller.play() }
/// Slider(value: $controller.progress, in: 0...1)
/// ```
@Observable
@MainActor
public final class RoutePreviewController {
    // MARK: - Public State

    /// Current playback state.
    public private(set) var playbackState: RoutePreviewPlaybackState = .stopped

    /// Current progress along the route, from 0.0 (start) to 1.0 (end).
    ///
    /// Set directly for scrubbing. During playback, this is updated automatically.
    public var progress: Float {
        get { _progress }
        set { _progress = max(0, min(1, newValue)) }
    }

    private var _progress: Float = 0

    /// Playback speed multiplier. Default is 1.0.
    ///
    /// At speed 1.0, the full route plays in `duration` seconds. At 2.0, it plays in half the time.
    public var speed: Float = 1.0

    /// Total duration in seconds for a full route playthrough at speed 1.0.
    public var duration: TimeInterval = 30.0

    /// Whether the animation should loop back to the start when it reaches the end.
    public var loops: Bool = false

    // MARK: - Internal Timing State

    /// Timestamp of the last frame update.
    var lastUpdateTime: Date?

    private let logger = Logger(maquette: "RoutePreviewController")

    // MARK: - Init

    /// Creates a route preview controller with default settings.
    ///
    /// - Parameters:
    ///   - duration: Total playback duration at speed 1.0. Default is 30 seconds.
    ///   - speed: Playback speed multiplier. Default is 1.0.
    ///   - loops: Whether to loop at the end. Default is `false`.
    public init(duration: TimeInterval = 30.0, speed: Float = 1.0, loops: Bool = false) {
        self.duration = duration
        self.speed = speed
        self.loops = loops
    }

    // MARK: - Playback Controls

    /// Starts or resumes playback from the current progress.
    public func play() {
        guard playbackState != .playing else { return }
        lastUpdateTime = nil
        playbackState = .playing
        logger.debug("Route preview playing from progress \(self.progress)")
    }

    /// Pauses playback at the current progress.
    public func pause() {
        guard playbackState == .playing else { return }
        playbackState = .paused
        lastUpdateTime = nil
        logger.debug("Route preview paused at progress \(self.progress)")
    }

    /// Toggles between playing and paused states.
    public func togglePlayPause() {
        switch playbackState {
        case .stopped, .paused:
            play()
        case .playing:
            pause()
        }
    }

    /// Stops playback and resets progress to 0.
    public func stop() {
        playbackState = .stopped
        progress = 0
        lastUpdateTime = nil
        logger.debug("Route preview stopped")
    }

    /// Seeks to a specific progress value. If playing, playback continues from the new position.
    ///
    /// - Parameter newProgress: The target progress value (0...1).
    public func seek(to newProgress: Float) {
        progress = newProgress
        if playbackState == .playing {
            lastUpdateTime = nil
        }
    }

    // MARK: - Frame Update

    /// Advances the animation based on the current timestamp.
    ///
    /// Called each frame by the platform view's `TimelineView`. Returns `true` if the
    /// animation state changed (i.e., the progress or entities need updating).
    ///
    /// - Parameter date: The current frame timestamp from `TimelineView`.
    /// - Returns: `true` if the frame produced a change requiring entity updates.
    @discardableResult
    func update(at date: Date) -> Bool {
        guard playbackState == .playing else { return false }

        guard let lastTime = lastUpdateTime else {
            lastUpdateTime = date
            return false
        }

        let deltaTime = date.timeIntervalSince(lastTime)
        lastUpdateTime = date

        // Guard against large jumps (e.g., app backgrounded)
        let clampedDelta = min(deltaTime, 0.1)

        let increment = Float(clampedDelta / duration) * speed
        progress += increment

        if progress >= 1.0 {
            if loops {
                progress = progress.truncatingRemainder(dividingBy: 1.0)
            } else {
                progress = 1.0
                playbackState = .stopped
                lastUpdateTime = nil
                logger.debug("Route preview reached end")
            }
        }

        return true
    }
}
