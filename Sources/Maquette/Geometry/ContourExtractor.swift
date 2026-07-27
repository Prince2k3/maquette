import Foundation
import simd

/// Extracts isolines from a triangle mesh: the set of segments where one coordinate holds a
/// constant value across the surface.
///
/// Elevation contours are isolines of Y. A graticule draped over the terrain is isolines of X and Z,
/// which is why this takes the axis as an argument rather than assuming the vertical one — the two
/// look nothing alike on screen but are the same operation, and writing it twice would mean two
/// places to get the crossing test wrong.
///
/// Working from the chunk's own triangles rather than from the height field is what makes the lines
/// stop exactly on the outline. The surface has already been clipped to the boundary, so an isoline
/// inherits that clip for free, concave corners included; sampling the height field on a grid would
/// instead need the whole boundary clip repeated.
enum ContourExtractor {
    /// A single straight piece of an isoline, in the mesh's own space.
    struct Segment: Equatable {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
    }

    /// Which coordinate the isolines hold constant.
    enum Axis {
        case x, y, z

        func value(of position: SIMD3<Float>) -> Float {
            switch self {
            case .x: return position.x
            case .y: return position.y
            case .z: return position.z
            }
        }
    }

    /// An evenly spaced set of levels.
    ///
    /// Held as a start and a step rather than an array so a triangle can work out which levels cross
    /// it with arithmetic instead of a search. That is the whole reason extracting twenty levels
    /// costs barely more than extracting one: a triangle only ever visits the handful of levels
    /// inside its own span.
    struct LevelSet: Equatable {
        var first: Float
        var step: Float
        var count: Int

        /// Levels spread through a range, excluding the range's own ends where nothing would draw.
        ///
        /// - Parameters:
        ///   - lower: Bottom of the range.
        ///   - upper: Top of the range.
        ///   - count: How many levels to place inside it.
        static func dividing(_ lower: Float, _ upper: Float, into count: Int) -> LevelSet {
            guard count > 0, upper > lower else { return LevelSet(first: 0, step: 0, count: 0) }
            let step = (upper - lower) / Float(count + 1)
            return LevelSet(first: lower + step, step: step, count: count)
        }

        /// Levels at a fixed spacing, aligned to multiples of that spacing rather than to the
        /// range's lower end, so the lines stay put as terrain pans beneath them.
        static func spaced(_ step: Float, from lower: Float, to upper: Float) -> LevelSet {
            guard step > 0, upper > lower else { return LevelSet(first: 0, step: 0, count: 0) }
            let firstIndex = (lower / step).rounded(.down) + 1
            let first = firstIndex * step
            guard first <= upper else { return LevelSet(first: 0, step: 0, count: 0) }
            let count = Int(((upper - first) / step).rounded(.down)) + 1
            return LevelSet(first: first, step: step, count: count)
        }

        func level(_ index: Int) -> Float { first + step * Float(index) }
    }

    /// Where a line meets the mesh, named by the edge it crosses rather than by a point.
    ///
    /// Kept as an edge and a parameter rather than resolved on the spot so the two ends of a segment
    /// can be compared before either is turned into a point, which is what settles a degenerate
    /// crossing without touching the position buffer twice.
    private struct Crossing {
        var from: UInt32
        var to: UInt32
        /// How far along `from`→`to` the level falls.
        var t: Float

        func point(in positions: UnsafeBufferPointer<SIMD3<Float>>) -> SIMD3<Float> {
            let p = positions[Int(from)]
            return p + (positions[Int(to)] - p) * t
        }
    }

    /// Extracts every isoline segment of `levels` from a triangle mesh.
    ///
    /// - Parameters:
    ///   - positions: Vertex positions.
    ///   - indices: Triangle list, three indices per triangle.
    ///   - axis: Which coordinate the levels are measured along.
    ///   - levels: The values to trace.
    /// - Returns: Unordered segments. They are not joined into paths: each one is drawn as its own
    ///   quad, and adjacent segments already share endpoints, so ordering buys nothing.
    static func isolines(
        positions: [SIMD3<Float>],
        indices: [UInt32],
        axis: Axis,
        levels: LevelSet
    ) -> [Segment] {
        var segments: [Segment] = []
        segments.reserveCapacity(indices.count / 3)
        positions.withUnsafeBufferPointer { points in
            trace(points: points, indices: indices, axis: axis, levels: levels) { a, b in
                segments.append(Segment(a: a.point(in: points), b: b.point(in: points)))
            }
        }
        return segments
    }

    /// Walks the mesh, handing each isoline segment to `emit` as a pair of edge crossings.
    private static func trace(
        points: UnsafeBufferPointer<SIMD3<Float>>,
        indices: [UInt32],
        axis: Axis,
        levels: LevelSet,
        emit: (Crossing, Crossing) -> Void
    ) {
        guard levels.count > 0, levels.step > 0, indices.count >= 3 else { return }

        indices.withUnsafeBufferPointer { triangles in
            var base = 0
            while base + 2 < triangles.count {
                let i0 = triangles[base], i1 = triangles[base + 1], i2 = triangles[base + 2]
                base += 3
                let n = UInt32(points.count)
                guard i0 < n, i1 < n, i2 < n else { continue }

                let p0 = points[Int(i0)], p1 = points[Int(i1)], p2 = points[Int(i2)]
                let s0 = axis.value(of: p0), s1 = axis.value(of: p1), s2 = axis.value(of: p2)
                let low = min(s0, min(s1, s2))
                let high = max(s0, max(s1, s2))

                // Widened by one level at each end on purpose. The index arithmetic is the fast
                // path, not the decision — the crossing test below is what actually settles
                // whether a level touches this triangle, so a wasted iteration costs nothing
                // while a missed one silently puts a hole in a line.
                var index = Int(((low - levels.first) / levels.step).rounded(.down))
                let last = Int(((high - levels.first) / levels.step).rounded(.down)) + 1
                index = max(index, 0)

                while index <= last && index < levels.count {
                    defer { index += 1 }
                    let level = levels.level(index)

                    // A vertex sitting exactly on the level counts as above it, consistently, so
                    // a line running through a shared vertex is emitted once rather than twice.
                    let b0 = s0 < level, b1 = s1 < level, b2 = s2 < level

                    // Held in two locals rather than an array, which is worth far more than it
                    // looks. Gathering the ends into an `Array` here is the same mistake the 3D
                    // Tiles clip made with its per-triangle array literal, and it is the single
                    // thing that decides this effect's pan cost: measured back to back from one
                    // binary — an environment variable picked the arm — eight scripted drags on
                    // the Hologram preset cost 24.2 ms of effect per step with the allocation
                    // against 6.6 ms without it, the allocation-free arm winning every paired step
                    // by a margin some 35× the drift this host shows between identical runs.
                    var first = Crossing(from: 0, to: 0, t: 0)
                    var second = first
                    var found = 0
                    if b0 != b1 {
                        first = Self.crossing(i0, s0, i1, s1, level); found = 1
                    }
                    if b1 != b2 {
                        let edge = Self.crossing(i1, s1, i2, s2, level)
                        if found == 0 { first = edge; found = 1 } else { second = edge; found = 2 }
                    }
                    if b2 != b0, found < 2 {
                        let edge = Self.crossing(i2, s2, i0, s0, level)
                        if found == 0 { first = edge; found = 1 } else { second = edge; found = 2 }
                    }

                    guard found == 2 else { continue }
                    guard first.point(in: points) != second.point(in: points) else { continue }
                    emit(first, second)
                }
            }
        }
    }

    /// Where along an edge the scalar reaches `level`.
    private static func crossing(
        _ p: UInt32, _ sp: Float,
        _ q: UInt32, _ sq: Float,
        _ level: Float
    ) -> Crossing {
        let span = sq - sp
        guard abs(span) > .ulpOfOne else { return Crossing(from: p, to: q, t: 0) }
        return Crossing(from: p, to: q, t: (level - sp) / span)
    }
}
