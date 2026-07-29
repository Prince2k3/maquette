import Foundation
import RealityKit
import simd

/// A triangle mesh under construction, in the layout `Tiles3DMeshBuffer` draws from.
///
/// Named for what it is rather than for its first caller, the same way `Tiles3DMeshBuffer` is: the
/// hologram's ribbons, its pedestal, and the extruded building footprints all accumulate here, and
/// all of them are handed to the buffer the same way.
///
/// It tracks its own bounds as vertices arrive, because `Tiles3DMeshBuffer.write` needs them and a
/// second pass over the positions to find them would be pure waste.
struct IndexedMesh {
    private(set) var vertices: [Tiles3DVertex] = []
    private(set) var indices: [UInt32] = []
    private var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

    var isEmpty: Bool { indices.isEmpty }

    var bounds: BoundingBox {
        isEmpty ? BoundingBox() : BoundingBox(min: lo, max: hi)
    }

    mutating func reserve(vertices count: Int, indices indexCount: Int) {
        vertices.reserveCapacity(count)
        indices.reserveCapacity(indexCount)
    }

    mutating func removeAll() {
        vertices.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
        lo = SIMD3(repeating: .greatestFiniteMagnitude)
        hi = SIMD3(repeating: -.greatestFiniteMagnitude)
    }

    /// Appends a vertex and returns its index.
    @discardableResult
    mutating func append(position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>) -> UInt32 {
        lo = simd_min(lo, position)
        hi = simd_max(hi, position)
        vertices.append(Tiles3DVertex(position: position, normal: normal, uv: uv))
        return UInt32(vertices.count - 1)
    }

    mutating func appendTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        indices.append(contentsOf: [a, b, c])
    }

    /// Appends triangles wholesale, for topology that is carried over rather than built.
    ///
    /// A caller reusing another mesh's indices unchanged — which is what an effect that only moves
    /// vertices does — would otherwise pay `appendTriangle`'s per-triangle array literal for every one
    /// of them. That is the same heap traffic `InkGeometry.addTubes` was measured losing time to.
    mutating func appendIndices(_ source: [UInt32]) {
        indices.append(contentsOf: source)
    }
}
