#if MAQUETTE_PROFILING && (os(iOS) || os(macOS))
import Foundation
import QuartzCore
#if os(macOS)
import AppKit
#endif

/// An opt-in diagnostic clock comparing the display link with RealityKit scene updates.
/// Callbacks are input opportunities, not proof
/// that RealityKit presented a distinct frame. Never queue a burst of stale input callbacks.
@MainActor
final class DioramaProfileFrameClock: NSObject {
    var onFrame: (@MainActor () -> Void)?
    var onSceneFrame: (@MainActor () -> Void)?
    let usesSceneUpdates = ProcessInfo.processInfo.environment["MAQUETTE_PROFILE_DRIVER"] != "displayLink"
    let frames: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var displayLink: CADisplayLink?
    private var lastCallbackTime: CFTimeInterval?
    private(set) var sourceIntervals: [Double] = []
    private(set) var periods: [Double] = []
    private(set) var lateness: [Double] = []

    override init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = stream.stream
        continuation = stream.continuation
        super.init()
        guard !usesSceneUpdates else { return }
        #if os(macOS)
        displayLink = NSScreen.main?.displayLink(target: self, selector: #selector(frame(_:)))
        #else
        displayLink = CADisplayLink(target: self, selector: #selector(frame(_:)))
        #endif
        guard let displayLink else { continuation.finish(); return }
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func frame(_ link: CADisplayLink) {
        recordCallback()
        sourceIntervals.append((link.targetTimestamp - link.timestamp) * 1000)
        lateness.append(max(0, CACurrentMediaTime() - link.targetTimestamp) * 1000)
        onFrame?()
        continuation.yield(())
    }

    func sceneFrame(deltaTime: TimeInterval) {
        onSceneFrame?()
        guard usesSceneUpdates else { return }
        recordCallback()
        sourceIntervals.append(deltaTime * 1000)
        onFrame?()
        continuation.yield(())
    }

    private func recordCallback() {
        let now = CACurrentMediaTime()
        if let previous = lastCallbackTime { periods.append((now - previous) * 1000) }
        lastCallbackTime = now
    }

    func stop() {
        onFrame = nil
        onSceneFrame = nil
        displayLink?.invalidate()
        displayLink = nil
        continuation.finish()
    }
}
#endif
