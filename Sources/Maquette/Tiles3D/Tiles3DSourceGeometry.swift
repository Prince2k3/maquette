import Foundation
import RealityKit
import simd

/// A tile's geometry as it arrived, kept so it can be cut again against a moved outline.
///
/// Clipping is destructive: it bakes the tile's placement into the vertices and discards everything
/// outside the outline. That is the right trade for a fixed diorama, where the cut is made once and
/// never revisited. Panning slides the outline across the model, so a tile that was wholly interior
/// becomes a rim tile and has to be cut where it never was before — and there is nothing left of it
/// to cut. The only alternative would be re-fetching every tile the outline now touches, on every
/// pan step.
///
/// So this is retained only when the diorama can actually pan. A fixed one keeps paying nothing.
struct Tiles3DSourceGeometry {
    /// The mesh parts as the tile delivered them, in the tile's own space.
    let descriptors: [MeshDescriptor]
    /// Where the tile sits, in the geometry's space. Applied during the cut rather than left on the
    /// entity, because it carries rotation.
    let placement: simd_float4x4
    /// The tile's imagery.
    ///
    /// Held here rather than read back off the entity because a tile that starts outside the
    /// outline has no mesh to read it from, and panning towards it is exactly when it is needed.
    let material: RealityKit.Material
    /// The tile's horizontal extent once placed.
    let lowerBound: SIMD2<Float>
    /// The tile's horizontal extent once placed.
    let upperBound: SIMD2<Float>

    init(descriptors: [MeshDescriptor], placement: simd_float4x4, material: RealityKit.Material) {
        self.descriptors = descriptors
        self.placement = placement
        self.material = material

        var lower = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for descriptor in descriptors {
            for position in descriptor.positions.elements {
                let placed = placement * SIMD4(position.x, position.y, position.z, 1)
                let point = SIMD2(placed.x, placed.z)
                lower = simd_min(lower, point)
                upper = simd_max(upper, point)
            }
        }
        self.lowerBound = lower
        self.upperBound = upper
    }

    /// Whether moving the outline from one position to another changes how this tile is cut.
    ///
    /// This is what keeps panning affordable. A pan step moves the outline a little, so almost
    /// every tile is either still wholly inside it — surviving whole, exactly as it already is — or
    /// still wholly outside it, contributing nothing either way. Only the tiles the outline's edge
    /// actually crosses have a different answer than before, and only those are rebuilt. The rest
    /// ride along on the container's transform without being touched.
    func needsRecut(from old: BoundaryPrism?, to new: BoundaryPrism?) -> Bool {
        Self.needsRecut(lower: lowerBound, upper: upperBound, from: old, to: new)
    }

    /// The decision `needsRecut` makes, in terms of a horizontal extent alone.
    static func needsRecut(
        lower: SIMD2<Float>,
        upper: SIMD2<Float>,
        from old: BoundaryPrism?,
        to new: BoundaryPrism?
    ) -> Bool {
        let before = old?.containment(of: lower, upper) ?? .inside
        let after = new?.containment(of: lower, upper) ?? .inside
        guard before == after else { return true }
        // Unchanged and definite means the previous cut still holds. Unchanged and `straddling`
        // does not: the outline crossed this tile before and crosses it still, but not along the
        // same line, so the cut has to be made again.
        return before == .straddling
    }
}

extension BoundaryPrism {
    /// How a horizontal box sits relative to the outline.
    enum Containment {
        /// Entirely within the outline, so a clip would keep it whole.
        case inside
        /// Entirely beyond the outline, so a clip would discard it.
        case outside
        /// The outline's edge crosses it, so a clip would cut it.
        case straddling
    }

    /// Where a horizontal box sits relative to the outline, without clipping anything.
    ///
    /// Deliberately conservative: it answers `inside` or `outside` only when that is certain, and
    /// `straddling` whenever it cannot tell. The caller uses this to skip work, so a wrong
    /// certainty would leave stale geometry on screen while a needless `straddling` only costs a
    /// rebuild.
    ///
    /// Four corners inside a *convex* region put the whole box inside it, since the box is the
    /// convex hull of its corners. A concave outline gives no such guarantee — a notch can pass
    /// between the corners — so a split outline reports `straddling` and is simply re-cut.
    func containment(of lower: SIMD2<Float>, _ upper: SIMD2<Float>) -> Containment {
        if upper.x < lowerBound.x || lower.x > upperBound.x
            || upper.y < lowerBound.y || lower.y > upperBound.y {
            return .outside
        }
        guard pieces.count == 1 else { return .straddling }

        let corners = [lower, SIMD2(upper.x, lower.y), upper, SIMD2(lower.x, upper.y)]
        return corners.allSatisfy(contains) ? .inside : .straddling
    }
}
