import Foundation
import simd

/// Which raw elevation sits at diorama Y = 0, as a function of how far the ground has been zoomed.
///
/// At the scale a chunk is generated at this is the library's plain vertical convention — Y = 0 is
/// the lowest terrain in the region — and nothing here does anything. It exists for the ground zoom,
/// which has one free variable left and has to spend it here.
///
/// ## Why the datum has to move
///
/// What the eye reads off a chunk's silhouette is the strata band: the ochre stripe between the
/// terrain and the underside, whose height is `baseDepth + rimY`. Both of its terms are otherwise
/// spoken for.
///
/// - `baseDepth` is fixed at generation. The earth mass is what the wall is *made of*, so a depth
///   that rode the zoom would answer a gesture about the map by resizing the object — the wall
///   growing as the ground widens and shrinking on the way back in, which is the one thing anybody
///   looking at the chunk actually notices.
/// - `rimY` is `(rim − baseline) · elevationScale`, and the elevation scale divides by the ground
///   scale. It must: twice the ground across the same physical width makes a metre of relief worth
///   half as many diorama metres, and held fixed a 6,000 m peak would be most of the chunk's height
///   by the time the map reached the globe.
///
/// So the baseline is what is left, and pinning `rimY` says exactly what it has to be:
///
///     (rim − B(s))·E₀/s = (rim − B₀)·E₀   ⟹   B(s) = rim − s·(rim − B₀)
///
/// which is the terrain compressed about the rim rather than about its own floor. Zoomed out the
/// whole terrain floats above Y = 0 by `rimY₀·(s − 1)/s`; zoomed in it sinks below.
///
/// ## Three things to have in hand before changing this
///
/// - **The rim is a mean, so what is pinned is the mean.** The band's waviness — the rim riding up a
///   ridge and down a valley around the loop — compresses by `1/s` with everything else, so the ring
///   evens out as the map widens rather than holding its profile. Pinning every point would need an
///   underside that copied the rim, and that is the underside moving again.
/// - **Y = 0 stops meaning "the lowest ground".** Every consumer follows, because they all read the
///   datum from ``TerrainHeightField`` rather than restating it — but a zoom *in* puts low ground
///   below the base, where `TerrainSolidGenerator.resample` clamps it flat. That clamp is not new:
///   panning far enough has always found ground below a frozen baseline. A zoom-in is just a much
///   quicker way to reach it.
/// - **It is a pure function of the scale.** Nothing is measured from what is on screen, so neither
///   a pan nor a roll can move it — the same discipline that keeps the chunk from bobbing as tiles
///   arrive, arriving here for free rather than by freezing a measurement each step.
struct GroundDatum: Sendable, Equatable {
    /// The raw elevation at Y = 0 when the chunk was generated: the lowest ground in the region.
    let generated: Float
    /// The raw elevation the chunk's rim stood at when it was generated, averaged along the outline.
    let rim: Float

    /// The raw elevation that has to sit at diorama Y = 0 for the strata band to keep its height
    /// when the ground is zoomed by `scale`.
    func baseline(atGroundScale scale: Float) -> Float {
        guard scale > 0 else { return generated }
        return rim - scale * (rim - generated)
    }

    /// The diorama height the rim is held at, given the elevation scale the chunk was *generated*
    /// with — the invariant ``baseline(atGroundScale:)`` exists to preserve, and the quantity to
    /// compare a measured rim against when this misbehaves.
    func rimHeight(generatedElevationScale: Float) -> Float {
        (rim - generated) * generatedElevationScale
    }

    /// Measures the datum for a freshly-generated chunk.
    ///
    /// The rim is weighted by edge length rather than averaged over the vertices, because a
    /// boundary's vertices are not evenly spaced: a circle's are, but a real-world outline crowds
    /// them wherever the coastline is fiddly, and an unweighted mean would let one detailed headland
    /// speak for the whole loop.
    ///
    /// Sampled at pan offset zero through the height field the chunk was generated from, so it is
    /// the rim the solid actually has rather than the rim of some other sampling of the same ground.
    static func measured(
        boundary: DioramaBoundary,
        heightField: TerrainHeightField
    ) -> GroundDatum {
        let generated = heightField.baselineElevation
        let vertices = boundary.vertices
        guard vertices.count >= 2 else { return GroundDatum(generated: generated, rim: generated) }

        var weighted: Float = 0
        var total: Float = 0
        for index in vertices.indices {
            let start = vertices[index]
            let end = vertices[(index + 1) % vertices.count]
            let length = simd_length(end - start)
            guard length > 0 else { continue }
            let middle = (start + end) / 2
            weighted += heightField.rawElevation(atX: middle.x, z: middle.y) * length
            total += length
        }
        guard total > 0 else { return GroundDatum(generated: generated, rim: generated) }
        return GroundDatum(generated: generated, rim: weighted / total)
    }
}
