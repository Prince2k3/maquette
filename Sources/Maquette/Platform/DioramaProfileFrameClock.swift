#if MAQUETTE_PROFILING && (os(iOS) || os(macOS))
import Foundation
import QuartzCore
#if os(macOS)
import AppKit
#endif

/// A bounded, display-driven diagnostic clock. Callbacks are input opportunities, not proof
/// that RealityKit presented a distinct frame. Never queue a burst of stale input callbacks.
@MainActor
final class DioramaProfileFrameClock: NSObject {
    var onFrame: (@MainActor () -> Void)?
    let frames: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var displayLink: CADisplayLink?

    override init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = stream.stream
        continuation = stream.continuation
        super.init()
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
        onFrame?()
        continuation.yield(())
    }

    func stop() {
        onFrame = nil
        displayLink?.invalidate()
        displayLink = nil
        continuation.finish()
    }
}
#endif
