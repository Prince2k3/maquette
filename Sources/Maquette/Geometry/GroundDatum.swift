import Foundation
import simd

/// Which raw elevation sits at diorama Y = 0, as a function of how far the ground has been zoomed.
///
/// At the scale a chunk is generated at this is the library's plain vertical convention — Y = 0 is
/// the lowest terrain in the region — and nothing here does anything. It exists for the ground zoom,
/// which has one free variable left and has to spend it here.
///
/// The datum compresses terrain about its generated mean rim, rather than about the fetched
/// region's lowest point. With generated baseline B₀, generated elevation scale E₀ and ground
/// scale s, pinning the mean rim requires B(s) = rim − s·(rim − B₀).
///
/// The rim is weighted by edge length and measured once at generation; panning and tile arrivals
/// never remeasure it, so they cannot make the terrain bob. Y = 0 stops meaning the lowest ground
/// after a zoom. `TerrainSolidGenerator` independently limits the earth beneath each surface point
/// to a shallow slice, raising its underside where necessary; pinning this datum no longer means
/// preserving the height of an arbitrarily deep block.
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
