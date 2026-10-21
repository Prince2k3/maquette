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
    // Return true only when the waiting tour needs to end its phase.
    var onFrame: (@MainActor () -> Bool)?
    var onSceneFrame: (@MainActor () -> Void)?
    let usesSceneUpdates: Bool
    let frames: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var displayLink: CADisplayLink?
    private var isStopped = false
    private(set) var completionWakeups = 0
    private var lastCallbackTime: CFTimeInterval?
    private(set) var sourceIntervals: [Double] = []
    private(set) var periods: [Double] = []
    private(set) var lateness: [Double] = []

    init(sceneUpdates: Bool = ProcessInfo.processInfo.environment["MAQUETTE_PROFILE_DRIVER"] != "displayLink") {
        usesSceneUpdates = sceneUpdates
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
        deliverInput()
    }

    func sceneFrame(deltaTime: TimeInterval) {
        guard !isStopped else { return }
        onSceneFrame?()
        guard usesSceneUpdates else { return }
        recordCallback()
        sourceIntervals.append(deltaTime * 1000)
        deliverInput()
    }

    private func deliverInput() {
        if onFrame?() == true {
            completionWakeups += 1
            continuation.yield(())
        }
    }

    private func recordCallback() {
        let now = CACurrentMediaTime()
        if let previous = lastCallbackTime { periods.append((now - previous) * 1000) }
        lastCallbackTime = now
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        onFrame = nil
        onSceneFrame = nil
        displayLink?.invalidate()
        displayLink = nil
        continuation.finish()
    }
}
#endif
