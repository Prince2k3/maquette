import Testing
import simd

@testable import Maquette

/// A drag as the two clocks actually deliver it: touches sampled at one rate, frames running at
/// another, and each frame reporting the movement since whatever the newest touch was last time.
///
/// The finger moves at a constant speed throughout, so every bit of variation in what the gesture
/// hands over is the beat between the two rates and nothing else.
private struct ScriptedDrag {
    /// The rate the simulator injects touches at, against a 60 Hz frame.
    var touchRate: Double = 0.008
    var frameRate: Double = 1.0 / 60
    /// How late a touch is by the time the frame carrying it runs.
    var latency: Double = 0.002
    var speed: Float = 1
    var frames = 30

    /// Each frame's time, and the newest touch it saw.
    var deliveries: [(frame: Double, touch: Double)] {
        (1...frames).map { index in
            let frame = Double(index) * frameRate
            return (frame, ((frame - latency) / touchRate).rounded(.down) * touchRate)
        }
    }

    /// What the gesture reports: the movement between one frame's newest touch and the next's.
    var events: [(delta: SIMD2<Float>, touch: Double, frame: Double)] {
        var result: [(SIMD2<Float>, Double, Double)] = []
        var previous: Double?
        for delivery in deliveries {
            defer { previous = delivery.touch }
            guard let previous else { continue }
            result.append((SIMD2(Float(delivery.touch - previous) * speed, 0), delivery.touch, delivery.frame))
        }
        return result
    }
}

private func coefficientOfVariation(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    let mean = values.reduce(0, +) / Float(values.count)
    guard mean != 0 else { return 0 }
    let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)
    return variance.squareRoot() / mean
}

@Suite("Pan path resampling")
struct PanPathResamplerTests {
    /// The whole point: a finger moving at one speed moves the ground at one speed, even though the
    /// deltas the gesture hands over do not.
    @Test func evenFramesMoveEvenlyThroughUnevenTouches() {
        let drag = ScriptedDrag()
        var resampler = PanPathResampler()
        var steps: [Float] = []
        var reported: [Float] = []

        for event in drag.events {
            resampler.add(event.delta, touchTime: event.touch, now: event.frame)
            steps.append(simd_length(resampler.step(now: event.frame)))
            reported.append(simd_length(event.delta))
        }

        // The first frames are the lag being taken up, and are not the steady state this is about.
        let settled = Array(steps.dropFirst(4))
        let raw = Array(reported.dropFirst(4))

        #expect(coefficientOfVariation(raw) > 0.1)
        #expect(coefficientOfVariation(settled) < coefficientOfVariation(raw) / 4)
    }

    /// Smoothing that lost distance would be a pan that does not follow the finger.
    @Test func theGroundLandsWhereTheFingerLeftIt() {
        let drag = ScriptedDrag()
        var resampler = PanPathResampler()
        var applied = SIMD2<Float>.zero
        var asked = SIMD2<Float>.zero

        for event in drag.events {
            resampler.add(event.delta, touchTime: event.touch, now: event.frame)
            applied += resampler.step(now: event.frame)
            asked += event.delta
        }

        // What is still in hand is the lag itself, and asking once more after the touches stop
        // lands it — which is what the store's tail step exists to do.
        #expect(resampler.hasUnappliedMovement)
        applied += resampler.step(now: drag.deliveries[drag.frames - 1].frame + 0.05)

        #expect(!resampler.hasUnappliedMovement)
        #expect(abs(applied.x - asked.x) < 1e-6)
    }

    /// A step must never show ground the finger has not reached: predicting would have to be taken
    /// back, and ground that runs on after the touch stops is the drift coalescing was added to fix.
    @Test func aStepNeverRunsPastTheNewestTouch() {
        let drag = ScriptedDrag()
        var resampler = PanPathResampler()
        var applied: Float = 0
        var asked: Float = 0

        for event in drag.events {
            resampler.add(event.delta, touchTime: event.touch, now: event.frame)
            asked += event.delta.x
            // Asked well after the frame it belongs to: even then the answer stops at the last touch.
            applied += resampler.step(now: event.frame + 1).x
            #expect(applied <= asked + 1e-6)
        }
    }

    /// Backwards is worse than late: a touch landing out of step must not drag the ground back over
    /// ground it has already covered.
    @Test func stepsOnlyEverGoForwards() {
        var resampler = PanPathResampler()
        var steps: [Float] = []

        // A jittery stream, including two touches sharing a timestamp and one arriving out of order.
        let script: [(touch: Double, frame: Double)] = [
            (0.000, 0.010), (0.008, 0.026), (0.008, 0.042), (0.024, 0.058),
            (0.020, 0.074), (0.036, 0.090), (0.044, 0.106), (0.060, 0.122),
        ]
        for entry in script {
            resampler.add(SIMD2(0.01, 0), touchTime: entry.touch, now: entry.frame)
            steps.append(resampler.step(now: entry.frame).x)
        }

        #expect(steps.allSatisfy { $0 >= 0 })
    }

    /// A gesture a minute after the last one must not interpolate across the gap between them, which
    /// would spend frames crawling through movement that never happened.
    @Test func aFreshGestureStartsAtOnce() {
        var resampler = PanPathResampler()
        resampler.add(SIMD2(0.01, 0), touchTime: 0.000, now: 0.010)
        _ = resampler.step(now: 0.010)
        resampler.add(SIMD2(0.01, 0), touchTime: 0.008, now: 0.021)
        _ = resampler.step(now: 0.021)

        // Mid-gesture, part of a touch interval is always still in hand.
        #expect(resampler.hasUnappliedMovement)

        resampler.add(SIMD2(0.05, 0), touchTime: 60.0, now: 60.010)
        let step = resampler.step(now: 60.010)

        // Everything the old gesture had left, plus the new movement, and no waiting for either.
        #expect(!resampler.hasUnappliedMovement)
        #expect(step.x > 0.05)
    }

    /// Input that timestamps nothing — a mouse — has no path to resample and is not held back.
    @Test func untimedInputIsNotHeldBack() {
        var resampler = PanPathResampler()
        var applied: Float = 0
        for index in 1...10 {
            let now = Double(index) * 0.016
            resampler.add(SIMD2(0.01, 0), touchTime: nil, now: now)
            applied += resampler.step(now: now).x
        }
        #expect(abs(applied - 0.1) < 1e-5)
        #expect(!resampler.hasUnappliedMovement)
    }
}
