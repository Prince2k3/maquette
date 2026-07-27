import simd

/// Where the photorealistic pan has to stop, given the ground that has actually arrived.
///
/// Split out of `Tiles3DEntity` because measuring the model needs a RealityKit scene while deciding
/// what the measurement *means* does not, and the deciding is the part that fails quietly. Both
/// failures here look like the model moving on its own rather than like a clamp misbehaving.
enum Tiles3DPanFrontier {
    /// The furthest the outline can slide while still standing entirely on loaded ground.
    ///
    /// Both arguments are in diorama meters: `groundLow`/`groundHigh` are the horizontal extent of
    /// the geometry on screen, and the outline is where the chunk's footprint sits when the offset
    /// is zero. A positive offset shows ground further along each axis, so the outline's near corner
    /// may travel as far as the ground's near corner and no further — and correspondingly for the
    /// far corner.
    static func limits(
        groundLow: SIMD2<Float>,
        groundHigh: SIMD2<Float>,
        outline: DioramaBoundary
    ) -> (low: SIMD2<Float>, high: SIMD2<Float>) {
        var low = groundLow - outline.minCorner
        var high = groundHigh - (outline.minCorner + outline.extent)

        // Less ground loaded than the outline covers, which is the ordinary state early in a
        // stream. The range is then inverted — there is no offset that puts the outline wholly on
        // geometry — and handing it back as-is would let `simd_clamp` return whichever bound it
        // reached first. Pin to the middle instead, which centres the outline on what there is.
        if low.x > high.x {
            let middle = (low.x + high.x) / 2
            low.x = middle
            high.x = middle
        }
        if low.y > high.y {
            let middle = (low.y + high.y) / 2
            low.y = middle
            high.y = middle
        }
        return (low, high)
    }

    /// Clamps a target offset to loaded ground without relocating ground already on screen.
    ///
    /// Relative for exactly the reason `TerrainRoller.clamp` is: the clamp exists to *refuse*
    /// movement onto geometry that is not there, and it must never *produce* movement. The two come
    /// apart routinely while streaming — a refinement round that retires a coarse ancestor shrinks
    /// the measured bounds, and the model is suddenly outside its own limits through no action of
    /// the user's. Clamping absolutely would haul it back on the next touch of any size, which reads
    /// as the model jumping while the finger barely moved. Admitting `current` into the range leaves
    /// a stranded offset where it is, able only to come back.
    static func clamp(
        _ target: SIMD2<Float>,
        to limits: (low: SIMD2<Float>, high: SIMD2<Float>),
        current: SIMD2<Float>
    ) -> SIMD2<Float> {
        simd_clamp(target, simd_min(limits.low, current), simd_max(limits.high, current))
    }
}
