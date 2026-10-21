#if MAQUETTE_PROFILING && (os(iOS) || os(macOS))
import Testing
@testable import Maquette

@Suite("Profile phase clock")
@MainActor
struct DioramaProfileFrameClockTests {
    @Test func sceneInputsOnlyWakeTheWaiterAtPhaseCompletion() async {
        let clock = DioramaProfileFrameClock(sceneUpdates: true)
        defer { clock.stop() }
        var inputs = 0, samples = 0
        clock.onSceneFrame = { samples += 1 }
        clock.onFrame = { inputs += 1; return inputs == 600 }
        for _ in 0..<599 { clock.sceneFrame(deltaTime: 1.0 / 60) }
        #expect(inputs == 599 && samples == 599)
        #expect(clock.completionWakeups == 0)
        clock.sceneFrame(deltaTime: 1.0 / 60)
        #expect(clock.completionWakeups == 1)
        var frames = clock.frames.makeAsyncIterator()
        let event = await frames.next()
        #expect(event != nil)
        clock.stop()
        clock.sceneFrame(deltaTime: 1.0 / 60)
        #expect(inputs == 600 && samples == 600)
        #expect(clock.sourceIntervals.count == 600)
        let end = await frames.next()
        #expect(end == nil)
    }

    @Test func cancellationEndsAPhaseWithoutSceneEvents() async {
        let clock = DioramaProfileFrameClock(sceneUpdates: true)
        defer { clock.stop() }
        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let waiter = Task { @MainActor in
            started.continuation.yield(())
            var frames = clock.frames.makeAsyncIterator()
            return await frames.next() == nil
        }
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        waiter.cancel()
        #expect(await waiter.value)
        started.continuation.finish()
        #expect(clock.completionWakeups == 0)
    }
}
#endif
