import Foundation
import simd

/// An axis-aligned rectangle of ground, in diorama space.
///
/// Panning is a question about two regions: the ground the outline needs buildings on now, and the
/// ground whose buildings are already in hand. Comparing them decides when to ask a provider for
/// more, and ``subtracting(_:)`` keeps that ask to the ground that is genuinely new — a chunk that
/// has slid a little needs a strip, not another copy of the city it is already standing on.
struct GroundBox: Sendable, Equatable {
    /// The corner at minimum X and Z.
    let lo: SIMD2<Float>
    /// The corner at maximum X and Z.
    let hi: SIMD2<Float>

    init(lo: SIMD2<Float>, hi: SIMD2<Float>) {
        self.lo = simd_min(lo, hi)
        self.hi = simd_max(lo, hi)
    }

    /// Grows the box by a margin on every side.
    func expanded(by margin: SIMD2<Float>) -> GroundBox {
        GroundBox(lo: lo - margin, hi: hi + margin)
    }

    func contains(_ other: GroundBox) -> Bool {
        other.lo.x >= lo.x && other.lo.y >= lo.y && other.hi.x <= hi.x && other.hi.y <= hi.y
    }

    func contains(_ point: SIMD2<Float>) -> Bool {
        point.x >= lo.x && point.x <= hi.x && point.y >= lo.y && point.y <= hi.y
    }

    /// Whether the two boxes share any area, touching counting as sharing.
    func overlaps(lo otherLo: SIMD2<Float>, hi otherHi: SIMD2<Float>) -> Bool {
        otherHi.x >= lo.x && otherLo.x <= hi.x && otherHi.y >= lo.y && otherLo.y <= hi.y
    }

    func intersection(_ other: GroundBox) -> GroundBox? {
        let lo = simd_max(self.lo, other.lo)
        let hi = simd_min(self.hi, other.hi)
        guard hi.x > lo.x, hi.y > lo.y else { return nil }
        return GroundBox(lo: lo, hi: hi)
    }

    /// The parts of this box that `other` does not cover, as up to four rectangles.
    ///
    /// Cut into bands rather than clipped as a polygon, so the pieces are rectangles a provider can
    /// be asked for directly. The strips beyond the overlap on each side of X take the box's full
    /// depth; the two remaining strips take only the width the overlap spans. So the pieces never
    /// overlap one another — a building near a seam would otherwise arrive twice — and together they
    /// cover exactly the difference.
    ///
    /// A box translated off its old position leaves two of them, which is the ordinary case for a
    /// pan: one strip ahead in X, one ahead in Z.
    func subtracting(_ other: GroundBox) -> [GroundBox] {
        guard let inner = intersection(other) else { return [self] }

        var pieces: [GroundBox] = []
        if inner.lo.x > lo.x {
            pieces.append(GroundBox(lo: lo, hi: SIMD2(inner.lo.x, hi.y)))
        }
        if inner.hi.x < hi.x {
            pieces.append(GroundBox(lo: SIMD2(inner.hi.x, lo.y), hi: hi))
        }
        if inner.lo.y > lo.y {
            pieces.append(GroundBox(lo: SIMD2(inner.lo.x, lo.y), hi: SIMD2(inner.hi.x, inner.lo.y)))
        }
        if inner.hi.y < hi.y {
            pieces.append(GroundBox(lo: SIMD2(inner.lo.x, inner.hi.y), hi: SIMD2(inner.hi.x, hi.y)))
        }
        return pieces
    }

    /// The latitude/longitude box this covers, for a provider that fetches by bounding box.
    ///
    /// Z counts southward in tile space, so the two corners come back with their latitudes the other
    /// way round. Taking the minimum and maximum rather than naming one of them north is what keeps
    /// that from quietly producing an inverted box, which a provider answers with nothing at all.
    func geographicBounds(
        anchor: TerrainAnchor
    ) -> (south: Double, west: Double, north: Double, east: Double) {
        let a = anchor.coordinate(forDioramaX: Double(lo.x), z: Double(lo.y))
        let b = anchor.coordinate(forDioramaX: Double(hi.x), z: Double(hi.y))
        return (
            south: min(a.latitude, b.latitude),
            west: min(a.longitude, b.longitude),
            north: max(a.latitude, b.latitude),
            east: max(a.longitude, b.longitude)
        )
    }
}
