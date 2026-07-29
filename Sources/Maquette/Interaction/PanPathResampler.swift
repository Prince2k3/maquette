import Foundation
import simd

/// Resamples a gesture's path so a pan step moves the ground by the *time* it covers rather than by
/// however much finger movement happened to be reported in it.
///
/// A drag arrives as touches sampled on the digitizer's clock and is applied on the display's, and
/// the two are not in phase. Coalescing already makes each frame apply one step, but that step is
/// whatever the touches added up to since the last one — so a frame that catches two touch samples
/// moves the ground two thirds as far as a frame that catches three. The total distance is right and
/// no frame is dropped, but the *speed* varies from frame to frame, which is what reads as judder.
///
/// So the path's points are kept with the timestamps the touches carry, and a step asks where the
/// finger was at a fixed offset behind the frame it is being applied on. Frames are evenly spaced,
/// so the answers are too, and the ground moves at the speed the finger did.
///
/// Two properties this has to keep, both of which are more important than the smoothing itself:
///
/// - **It never predicts.** The sample time is clamped to the newest touch, so a step can only ever
///   show ground the finger has already reached. Extrapolating would remove the lag below, and would
///   also overshoot every time the finger slowed — the ground running on past where the touch
///   stopped is the very thing coalescing was added to fix.
/// - **It never walks backwards.** The sample time only ever advances, so a late touch cannot pull
///   the ground back over ground it has already covered.
///
/// The cost is that the ground trails the finger by one touch interval — about 8 ms on a 120 Hz
/// display — and that the last of that interval's movement is left unapplied until something asks
/// for another step. ``hasUnappliedMovement`` is what tells the caller to come back for it, which is
/// what lands the ground exactly where the finger left it once the touches stop.
struct PanPathResampler {
    /// A point on the finger's path, in the clock steps are paced by.
    private struct Sample {
        var time: Double
        var position: SIMD2<Float>
    }

    /// How far back the path is kept. Enough to interpolate across a stalled frame or two; the
    /// sample time never travels back further than it already reached, so older points are dead.
    private static let historyLimit = 8

    /// A quiet spell this long starts a fresh gesture: the clocks are re-aligned and the old path is
    /// forgotten, so an hour-old touch cannot become one end of an interpolation.
    private static let burstGap: Double = 0.1

    /// A ceiling on the lag, so a hitch in the touch stream cannot turn into visible latency.
    private static let maximumLag: Double = 0.05

    private var samples: [Sample] = []
    /// Touch clock → step clock, captured once per gesture. Re-measuring it per touch would feed the
    /// touches' own jitter straight back into the sample time, which is the jitter being removed.
    private var clockOffset: Double = 0
    private var lastAdded: Double = 0
    private var cursor = -Double.infinity
    /// Whether this gesture's path has times of its own to be read against.
    private var isTimestamped = false
    private var total: SIMD2<Float> = .zero
    private var applied: SIMD2<Float> = .zero

    /// Whether the path has movement on it that no step has applied yet.
    var hasUnappliedMovement: Bool { applied != total }

    /// Adds a movement the gesture reported.
    ///
    /// - Parameters:
    ///   - delta: Movement in diorama meters.
    ///   - touchTime: When the touches behind it were sampled, in whatever clock the platform's
    ///     events carry. `nil` for inputs that timestamp nothing, which then resample against their
    ///     own arrival — harmless for a mouse, whose deltas are already frame-paced.
    ///   - now: The current time, in the clock steps are paced by.
    mutating func add(_ delta: SIMD2<Float>, touchTime: Double?, now: Double) {
        total += delta

        if samples.isEmpty || now - lastAdded > Self.burstGap {
            // Whatever is unapplied stays unapplied — `total` and `applied` carry across, so a
            // gesture that starts before the last one landed loses nothing.
            samples.removeAll(keepingCapacity: true)
            clockOffset = touchTime.map { now - $0 } ?? 0
            isTimestamped = touchTime != nil
            cursor = -.infinity
        }

        let time = touchTime.map { $0 + clockOffset } ?? now
        samples.append(Sample(time: time, position: total))
        if samples.count > Self.historyLimit { samples.removeFirst() }
        lastAdded = now
    }

    /// Returns how far to move the ground now.
    ///
    /// - Parameter now: The current time, in the clock steps are paced by.
    mutating func step(now: Double) -> SIMD2<Float> {
        guard let newest = samples.last else { return .zero }

        let lag = isTimestamped ? min(medianSpacing, Self.maximumLag) : 0
        cursor = min(max(now - lag, cursor), newest.time)

        let wanted = position(at: cursor)
        let step = wanted - applied
        applied = wanted
        return step
    }

    /// Forgets the path, keeping nothing to interpolate from or to catch up on.
    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        cursor = -.infinity
        total = .zero
        applied = .zero
    }

    /// How far behind the frame the path is read.
    ///
    /// The median rather than the latest spacing, and the median rather than a running average: the
    /// spacing between touches is quantized by the digitizer's own rate, so a stream that is
    /// perfectly regular still reports an occasional double interval as it beats against the frame
    /// rate. A median ignores those outright, where an average would move the lag a little on every
    /// one of them — and moving the lag is itself movement, subtracted from the step that frame.
    private var medianSpacing: Double {
        guard samples.count > 1 else { return 0 }
        var spacings: [Double] = []
        spacings.reserveCapacity(samples.count - 1)
        for index in 1..<samples.count {
            spacings.append(samples[index].time - samples[index - 1].time)
        }
        spacings.sort()
        return max(spacings[spacings.count / 2], 0)
    }

    /// Where the finger was at a time on the path, held at the ends rather than extended past them.
    private func position(at time: Double) -> SIMD2<Float> {
        guard let first = samples.first, let last = samples.last else { return applied }
        if time <= first.time { return first.position }
        if time >= last.time { return last.position }

        for index in 1..<samples.count where time <= samples[index].time {
            let after = samples[index]
            let before = samples[index - 1]
            let span = after.time - before.time
            guard span > 0 else { return after.position }
            let fraction = Float((time - before.time) / span)
            return before.position + (after.position - before.position) * fraction
        }
        return last.position
    }
}
