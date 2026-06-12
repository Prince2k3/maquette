import Foundation
import Testing
@testable import Maquette

@Suite("Route Preview Controller Tests")
struct RoutePreviewControllerTests {
    @Test("Initial state is stopped with zero progress")
    @MainActor
    func initialState() {
        let controller = RoutePreviewController()

        #expect(controller.playbackState == .stopped)
        #expect(controller.progress == 0)
        #expect(controller.speed == 1.0)
        #expect(controller.duration == 30.0)
        #expect(controller.loops == false)
    }

    @Test("Play sets state to playing")
    @MainActor
    func playTransition() {
        let controller = RoutePreviewController()
        controller.play()

        #expect(controller.playbackState == .playing)
    }

    @Test("Pause from playing sets state to paused")
    @MainActor
    func pauseTransition() {
        let controller = RoutePreviewController()
        controller.play()
        controller.pause()

        #expect(controller.playbackState == .paused)
    }

    @Test("Pause from stopped does nothing")
    @MainActor
    func pauseFromStopped() {
        let controller = RoutePreviewController()
        controller.pause()

        #expect(controller.playbackState == .stopped)
    }

    @Test("Stop resets progress to 0")
    @MainActor
    func stopResetsProgress() {
        let controller = RoutePreviewController()
        controller.play()
        controller.progress = 0.5
        controller.stop()

        #expect(controller.playbackState == .stopped)
        #expect(controller.progress == 0)
    }

    @Test("Toggle cycles play/pause correctly")
    @MainActor
    func togglePlayPause() {
        let controller = RoutePreviewController()

        // stopped → playing
        controller.togglePlayPause()
        #expect(controller.playbackState == .playing)

        // playing → paused
        controller.togglePlayPause()
        #expect(controller.playbackState == .paused)

        // paused → playing
        controller.togglePlayPause()
        #expect(controller.playbackState == .playing)
    }

    @Test("Progress is clamped to 0...1")
    @MainActor
    func progressClamping() {
        let controller = RoutePreviewController()

        controller.progress = -0.5
        #expect(controller.progress == 0)

        controller.progress = 1.5
        #expect(controller.progress == 1.0)

        controller.progress = 0.5
        #expect(controller.progress == 0.5)
    }

    @Test("Update advances progress based on elapsed time")
    @MainActor
    func updateAdvancesProgress() {
        let controller = RoutePreviewController(duration: 10.0)
        controller.play()

        let start = Date()
        // First call sets the base time
        controller.update(at: start)
        #expect(controller.progress == 0)

        // Simulate 0.05 seconds passing (within the 0.1s clamp)
        // Expected: (0.05 / 10.0) * 1.0 = 0.005
        let result = controller.update(at: start.addingTimeInterval(0.05))
        #expect(result == true)
        #expect(controller.progress > 0.004)
        #expect(controller.progress < 0.006)
    }

    @Test("Speed multiplier affects progress rate")
    @MainActor
    func speedMultiplier() {
        let controller = RoutePreviewController(duration: 10.0, speed: 2.0)
        controller.play()

        let start = Date()
        controller.update(at: start)

        // 0.05 seconds at 2x speed: (0.05 / 10) * 2 = 0.01
        controller.update(at: start.addingTimeInterval(0.05))
        #expect(controller.progress > 0.009)
        #expect(controller.progress < 0.011)
    }

    @Test("Small time steps accumulate correctly")
    @MainActor
    func smallTimeSteps() {
        let controller = RoutePreviewController(duration: 10.0, speed: 1.0)
        controller.play()

        let start = Date()
        controller.update(at: start)

        // 10 small steps of 0.05 seconds each = 0.5 seconds total
        for i in 1...10 {
            controller.update(at: start.addingTimeInterval(Double(i) * 0.05))
        }

        // Expected: 0.5 / 10.0 = 0.05
        #expect(controller.progress > 0.04)
        #expect(controller.progress < 0.06)
    }

    @Test("Speed 2x doubles progress rate with small steps")
    @MainActor
    func speed2xSmallSteps() {
        let controller = RoutePreviewController(duration: 10.0, speed: 2.0)
        controller.play()

        let start = Date()
        controller.update(at: start)

        for i in 1...10 {
            controller.update(at: start.addingTimeInterval(Double(i) * 0.05))
        }

        // Expected: (0.5 / 10.0) * 2.0 = 0.10
        #expect(controller.progress > 0.09)
        #expect(controller.progress < 0.11)
    }

    @Test("Playback stops at end when loops is false")
    @MainActor
    func stopsAtEnd() {
        let controller = RoutePreviewController(duration: 1.0)
        controller.play()
        controller.progress = 0.95

        let start = Date()
        controller.update(at: start)

        // Advance past the end
        controller.update(at: start.addingTimeInterval(0.1))

        #expect(controller.progress == 1.0)
        #expect(controller.playbackState == .stopped)
    }

    @Test("Playback wraps when loops is true")
    @MainActor
    func loopsAtEnd() {
        let controller = RoutePreviewController(duration: 1.0, loops: true)
        controller.play()
        controller.progress = 0.95

        let start = Date()
        controller.update(at: start)

        // Advance past the end
        controller.update(at: start.addingTimeInterval(0.1))

        #expect(controller.playbackState == .playing)
        #expect(controller.progress < 0.95) // Wrapped back to near start
    }

    @Test("Seek updates progress while maintaining playback state")
    @MainActor
    func seekMaintainsState() {
        let controller = RoutePreviewController()

        // Seek while stopped
        controller.seek(to: 0.5)
        #expect(controller.progress == 0.5)
        #expect(controller.playbackState == .stopped)

        // Seek while playing
        controller.play()
        controller.seek(to: 0.3)
        #expect(controller.progress == 0.3)
        #expect(controller.playbackState == .playing)

        // Seek while paused
        controller.pause()
        controller.seek(to: 0.7)
        #expect(controller.progress == 0.7)
        #expect(controller.playbackState == .paused)
    }

    @Test("Update returns false when not playing")
    @MainActor
    func updateReturnsFalseWhenStopped() {
        let controller = RoutePreviewController()
        let result = controller.update(at: Date())

        #expect(result == false)
    }

    @Test("Update returns false when paused")
    @MainActor
    func updateReturnsFalseWhenPaused() {
        let controller = RoutePreviewController()
        controller.play()
        controller.pause()

        let result = controller.update(at: Date())
        #expect(result == false)
    }

    @Test("Large time jumps are clamped to 0.1 seconds")
    @MainActor
    func largeTimeJumpClamped() {
        let controller = RoutePreviewController(duration: 10.0)
        controller.play()

        let start = Date()
        controller.update(at: start)

        // Jump 5 seconds — should be clamped to 0.1s
        controller.update(at: start.addingTimeInterval(5.0))

        // Expected: (0.1 / 10.0) * 1.0 = 0.01
        #expect(controller.progress > 0.005)
        #expect(controller.progress < 0.015)
    }

    @Test("Custom init parameters are stored correctly")
    @MainActor
    func customInit() {
        let controller = RoutePreviewController(duration: 60.0, speed: 0.5, loops: true)

        #expect(controller.duration == 60.0)
        #expect(controller.speed == 0.5)
        #expect(controller.loops == true)
    }

    @Test("Play is idempotent when already playing")
    @MainActor
    func playIdempotent() {
        let controller = RoutePreviewController()
        controller.play()
        controller.progress = 0.5

        // Playing again should not reset anything
        controller.play()
        #expect(controller.playbackState == .playing)
        #expect(controller.progress == 0.5)
    }
}
