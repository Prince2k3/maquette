import Foundation
import simd

/// The compute kernel that cuts tile geometry to the outline, and the layouts it shares with Swift.
///
/// The clip is the same algorithm `Tiles3DClipper` runs — the same grid rejection, the same two
/// circles for containment, the same Sutherland-Hodgman against the same convex pieces — restated
/// per triangle so a GPU can run 175,000 of them at once instead of one after another. Keeping the
/// two in step matters, so the shader is written to mirror the Swift line for line rather than to
/// look like idiomatic Metal; `Tiles3DGPUClipperTests` pins the two together on real geometry.
///
/// ## Why the source is a string
///
/// A `.metal` file in the target would be compiled into a resource bundle, and this package ships
/// no resources — the strata texture is drawn procedurally for the same reason. So the source is
/// compiled at runtime with `makeLibrary(source:)`, once, while tiles are still streaming. It costs
/// a fraction of a second at a moment when nothing is waiting on it.
enum Tiles3DClipKernel {
    /// Name of the kernel function in `source`.
    static let functionName = "tiles3d_clip"

    /// The most vertices a clipped polygon may reach before the tile is handed back to the CPU.
    ///
    /// Sutherland-Hodgman needs two polygons and a side array live at once, and on a GPU those are
    /// per-thread storage that every thread pays for whether or not it clips anything. Triangle ∩
    /// convex region can in principle reach 3 + the piece's edge count — 131 vertices against a
    /// circle — but only for a triangle large enough to swallow a stretch of the outline, which
    /// photogrammetry at these scales does not produce. Ten covers what actually arrives; anything
    /// past it sets the tile's overflow flag and the exact CPU clip finishes the job, so the bound
    /// costs occasional work and never geometry.
    static let maximumPolygonVertices = 10

    /// Words of the counter block each tile owns.
    static let countersPerTile = 12

    /// Offsets within a tile's counter block.
    enum Counter {
        static let vertexCount = 0
        static let indexCount = 1
        static let cutEdgeCount = 2
        static let overflow = 3
        /// Six words: minimum X, Y, Z then maximum X, Y, Z, each as an order-preserving `UInt32`.
        static let bounds = 4
    }

    /// Buffer indices, matched to the `[[buffer(n)]]` attributes in `source`.
    enum Slot {
        static let sourceVertices = 0
        static let sourceIndices = 1
        static let tile = 2
        static let prism = 3
        static let boundary = 4
        static let pieces = 5
        static let pieceEdges = 6
        static let grid = 7
        static let outVertices = 8
        static let outIndices = 9
        static let outCutEdges = 10
        static let counters = 11
    }

    // MARK: - Shared Layouts

    /// Everything about the outline that does not change from tile to tile.
    ///
    /// Field for field the same as `Prism` in `source`; `SIMD2<Float>` and Metal's `float2` agree on
    /// both size and alignment, so the two structures pack identically.
    struct Prism {
        var lowerBound: SIMD2<Float>
        var upperBound: SIMD2<Float>
        var gridCellScale: SIMD2<Float>
        var centroid: SIMD2<Float>
        var innerRadiusSquared: Float
        var outerRadiusSquared: Float
        var cutEdgeTolerance: Float
        var boundaryCount: UInt32
        var pieceCount: UInt32
        var gridResolution: UInt32
    }

    /// One convex region of the outline, as a range into the flattened edge list.
    struct Piece {
        var lowerBound: SIMD2<Float>
        var upperBound: SIMD2<Float>
        var edgeBegin: UInt32
        var edgeCount: UInt32
    }

    /// Where one tile's geometry starts in the shared scratch buffers, and how much room it has.
    struct Tile {
        var triangleCount: UInt32
        var vertexBase: UInt32
        var vertexCapacity: UInt32
        var indexBase: UInt32
        var indexCapacity: UInt32
        var cutBase: UInt32
        var cutCapacity: UInt32
        var counterBase: UInt32
    }

    /// A cut edge as the kernel writes it: three floats, three floats, one index.
    ///
    /// Deliberately not `Tiles3DCutEdge`, whose `SIMD3<Float>` members are 16-byte aligned and would
    /// disagree with the shader's `packed_float3`.
    struct CutEdge {
        var ax: Float, ay: Float, az: Float
        var bx: Float, by: Float, bz: Float
        var boundaryEdge: UInt32

        var resolved: Tiles3DCutEdge {
            Tiles3DCutEdge(a: SIMD3(ax, ay, az), b: SIMD3(bx, by, bz), boundaryEdge: Int(boundaryEdge))
        }
    }

    // MARK: - Order-Preserving Floats

    /// Metal has no atomic minimum over floats, so bounds are accumulated as integers whose ordering
    /// matches the floats they came from: flip the sign bit of a positive value, flip every bit of a
    /// negative one. Standard, and exactly reversible.
    static func decodeBound(_ key: UInt32) -> Float {
        let mask: UInt32 = (key >> 31) != 0 ? 0x8000_0000 : 0xFFFF_FFFF
        return Float(bitPattern: key ^ mask)
    }

    // MARK: - Source

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    #define MAX_POLYGON \(maximumPolygonVertices)

    #define COUNTER_VERTICES \(Counter.vertexCount)
    #define COUNTER_INDICES  \(Counter.indexCount)
    #define COUNTER_CUTS     \(Counter.cutEdgeCount)
    #define COUNTER_OVERFLOW \(Counter.overflow)
    #define COUNTER_BOUNDS   \(Counter.bounds)

    /// A vertex mid-clip, where interpolation happens. Not the packed drawing layout.
    struct ClipVertex {
        float3 position;
        float3 normal;
        float2 uv;
    };

    /// The layout the mesh is drawn from — `Tiles3DVertex` in Swift.
    struct PackedVertex {
        packed_float3 position;
        packed_float3 normal;
        packed_float2 uv;
    };

    struct CutEdge {
        packed_float3 a;
        packed_float3 b;
        uint boundaryEdge;
    };

    struct Prism {
        float2 lowerBound;
        float2 upperBound;
        float2 gridCellScale;
        float2 centroid;
        float innerRadiusSquared;
        float outerRadiusSquared;
        float cutEdgeTolerance;
        uint boundaryCount;
        uint pieceCount;
        uint gridResolution;
    };

    struct Piece {
        float2 lowerBound;
        float2 upperBound;
        uint edgeBegin;
        uint edgeCount;
    };

    struct Tile {
        uint triangleCount;
        uint vertexBase;
        uint vertexCapacity;
        uint indexBase;
        uint indexCapacity;
        uint cutBase;
        uint cutCapacity;
        uint counterBase;
    };

    /// Maps a float onto a uint of the same ordering, so atomic min and max can carry bounds.
    static inline uint orderable(float value) {
        uint bits = as_type<uint>(value);
        uint mask = ((bits >> 31) != 0) ? 0xFFFFFFFFu : 0x80000000u;
        return bits ^ mask;
    }

    /// Whether a horizontal position lies inside the outline.
    ///
    /// The two circles answer almost every query outright; only the annulus between them walks the
    /// outline. See `BoundaryPrism.contains`.
    static bool prismContains(float2 point,
                              constant Prism &prism,
                              device const float2 *boundary) {
        float2 offset = point - prism.centroid;
        float distanceSquared = dot(offset, offset);
        if (distanceSquared < prism.innerRadiusSquared) { return true; }
        if (distanceSquared > prism.outerRadiusSquared) { return false; }

        bool inside = false;
        uint count = prism.boundaryCount;
        uint j = count - 1;
        for (uint i = 0; i < count; ++i) {
            float2 a = boundary[i];
            float2 b = boundary[j];
            if ((a.y > point.y) != (b.y > point.y)) {
                float t = (point.y - a.y) / (b.y - a.y);
                if (point.x < a.x + t * (b.x - a.x)) { inside = !inside; }
            }
            j = i;
        }
        return inside;
    }

    /// Whether the outline can pass through a horizontal box. See `BoundaryPrism.mayCrossOutline`.
    static bool mayCrossOutline(float2 lower,
                                float2 upper,
                                constant Prism &prism,
                                device const uchar *grid) {
        uint resolution = prism.gridResolution;
        float limit = float(resolution - 1);
        float2 from = (lower - prism.lowerBound) * prism.gridCellScale;
        float2 to = (upper - prism.lowerBound) * prism.gridCellScale;
        // A stray tile vertex an Earth radius away makes these enormous, and a NaN would convert to
        // anything at all, so both are tamed before they become indices.
        from = select(from, float2(0.0f), from != from);
        to = select(to, float2(0.0f), to != to);
        uint2 first = uint2(clamp(from, 0.0f, limit));
        uint2 last = uint2(clamp(to, 0.0f, limit));
        for (uint y = first.y; y <= last.y; ++y) {
            for (uint x = first.x; x <= last.x; ++x) {
                if (grid[y * resolution + x] != 0) { return true; }
            }
        }
        return false;
    }

    /// Distance from a point to one boundary edge. See `DioramaBoundary.distance(from:toEdge:)`.
    static float edgeDistance(float2 point,
                              uint index,
                              constant Prism &prism,
                              device const float2 *boundary) {
        float2 a = boundary[index];
        float2 b = boundary[(index + 1) % prism.boundaryCount];
        float2 direction = b - a;
        float lengthSquared = dot(direction, direction);
        if (!(lengthSquared > 0.0f)) { return distance(point, a); }
        float t = clamp(dot(point - a, direction) / lengthSquared, 0.0f, 1.0f);
        return distance(point, a + direction * t);
    }

    /// The boundary edge a segment lies along, or -1. See `BoundaryPrism.boundaryEdge(along:_:)`.
    ///
    /// The midpoint test is what rejects a chord: two corners on the outline with the segment
    /// between them running through the interior, which a clipped triangle produces routinely.
    static int boundaryEdgeAlong(float2 a,
                                 float2 b,
                                 constant Prism &prism,
                                 device const float2 *boundary) {
        float tolerance = prism.cutEdgeTolerance;
        if (!(distance(a, b) > tolerance)) { return -1; }

        float2 midpoint = (a + b) * 0.5f;
        int best = -1;
        float bestDistance = tolerance;
        for (uint index = 0; index < prism.boundaryCount; ++index) {
            float d = edgeDistance(midpoint, index, prism, boundary);
            if (d > bestDistance) { continue; }
            if (edgeDistance(a, index, prism, boundary) > tolerance) { continue; }
            if (edgeDistance(b, index, prism, boundary) > tolerance) { continue; }
            bestDistance = d;
            best = int(index);
        }
        return best;
    }

    static inline ClipVertex crossing(ClipVertex from, ClipVertex to, float fromSide, float toSide) {
        float denominator = fromSide - toSide;
        if (!(fabs(denominator) > FLT_MIN)) { return from; }
        float t = clamp(fromSide / denominator, 0.0f, 1.0f);
        ClipVertex out;
        out.position = from.position + (to.position - from.position) * t;
        out.normal = from.normal + (to.normal - from.normal) * t;
        out.uv = from.uv + (to.uv - from.uv) * t;
        return out;
    }

    /// Clips a polygon against one convex piece's vertical planes.
    ///
    /// Each plane is classified before it is applied: a triangle is small next to the outline, so it
    /// lies wholly inside almost every one of a circle's 128 half-planes, and clipping against those
    /// is the identity. Wholly outside any one of them ends the work outright.
    static bool clipAgainstPiece(thread ClipVertex *polygon,
                                 thread uint &count,
                                 Piece piece,
                                 device const float4 *pieceEdges,
                                 thread bool &overflowed) {
        ClipVertex next[MAX_POLYGON];
        float sides[MAX_POLYGON];

        for (uint e = 0; e < piece.edgeCount; ++e) {
            float4 edge = pieceEdges[piece.edgeBegin + e];
            float2 origin = edge.xy;
            float2 direction = edge.zw - origin;

            bool anyInside = false;
            bool anyOutside = false;
            for (uint i = 0; i < count; ++i) {
                float side = direction.x * (polygon[i].position.z - origin.y)
                    - direction.y * (polygon[i].position.x - origin.x);
                sides[i] = side;
                if (side <= 0.0f) { anyInside = true; } else { anyOutside = true; }
            }

            if (!anyOutside) { continue; }
            if (!anyInside) { return false; }

            uint written = 0;
            ClipVertex previous = polygon[count - 1];
            float previousSide = sides[count - 1];

            for (uint i = 0; i < count; ++i) {
                ClipVertex current = polygon[i];
                float currentSide = sides[i];
                bool currentInside = currentSide <= 0.0f;
                bool previousInside = previousSide <= 0.0f;

                if (currentInside) {
                    if (!previousInside) {
                        if (written >= MAX_POLYGON) { overflowed = true; return false; }
                        next[written++] = crossing(previous, current, previousSide, currentSide);
                    }
                    if (written >= MAX_POLYGON) { overflowed = true; return false; }
                    next[written++] = current;
                } else if (previousInside) {
                    if (written >= MAX_POLYGON) { overflowed = true; return false; }
                    next[written++] = crossing(previous, current, previousSide, currentSide);
                }

                previous = current;
                previousSide = currentSide;
            }

            for (uint i = 0; i < written; ++i) { polygon[i] = next[i]; }
            count = written;
            if (count < 3) { return false; }
        }

        return count >= 3;
    }

    /// Reserves room for a polygon and writes it out as a fan, growing the tile's bounds to hold it.
    ///
    /// The reservation is unconditional so an overrun still reports how much room the tile actually
    /// needed; the write is what is skipped. Ordering between triangles is whatever the atomics
    /// happen to give, which is fine — triangles are independent and a mesh has no preferred order.
    static void emit(thread const ClipVertex *polygon,
                     uint count,
                     constant Tile &tile,
                     device PackedVertex *outVertices,
                     device uint *outIndices,
                     device atomic_uint *counters) {
        if (count < 3) { return; }
        uint indexCount = (count - 2) * 3;
        uint vertexBase = atomic_fetch_add_explicit(
            &counters[tile.counterBase + COUNTER_VERTICES], count, memory_order_relaxed);
        uint indexBase = atomic_fetch_add_explicit(
            &counters[tile.counterBase + COUNTER_INDICES], indexCount, memory_order_relaxed);

        if (vertexBase + count > tile.vertexCapacity || indexBase + indexCount > tile.indexCapacity) {
            atomic_fetch_max_explicit(
                &counters[tile.counterBase + COUNTER_OVERFLOW], 1u, memory_order_relaxed);
            return;
        }

        float3 lower = polygon[0].position;
        float3 upper = polygon[0].position;
        for (uint i = 0; i < count; ++i) {
            PackedVertex out;
            out.position = polygon[i].position;
            out.normal = polygon[i].normal;
            out.uv = polygon[i].uv;
            outVertices[tile.vertexBase + vertexBase + i] = out;
            lower = min(lower, polygon[i].position);
            upper = max(upper, polygon[i].position);
        }

        // Triangle ∩ convex region is convex, so a fan is a valid triangulation.
        for (uint offset = 1; offset + 1 < count; ++offset) {
            uint slot = tile.indexBase + indexBase + (offset - 1) * 3;
            outIndices[slot + 0] = vertexBase;
            outIndices[slot + 1] = vertexBase + offset;
            outIndices[slot + 2] = vertexBase + offset + 1;
        }

        device atomic_uint *bounds = &counters[tile.counterBase + COUNTER_BOUNDS];
        atomic_fetch_min_explicit(&bounds[0], orderable(lower.x), memory_order_relaxed);
        atomic_fetch_min_explicit(&bounds[1], orderable(lower.y), memory_order_relaxed);
        atomic_fetch_min_explicit(&bounds[2], orderable(lower.z), memory_order_relaxed);
        atomic_fetch_max_explicit(&bounds[3], orderable(upper.x), memory_order_relaxed);
        atomic_fetch_max_explicit(&bounds[4], orderable(upper.y), memory_order_relaxed);
        atomic_fetch_max_explicit(&bounds[5], orderable(upper.z), memory_order_relaxed);
    }

    /// Records the edges of a clipped polygon that ended up lying on the outline.
    static void collectCutEdges(thread const ClipVertex *polygon,
                                uint count,
                                constant Tile &tile,
                                constant Prism &prism,
                                device const float2 *boundary,
                                device CutEdge *outCutEdges,
                                device atomic_uint *counters) {
        if (count < 3) { return; }
        for (uint i = 0; i < count; ++i) {
            float3 a = polygon[i].position;
            float3 b = polygon[(i + 1) % count].position;
            int edge = boundaryEdgeAlong(float2(a.x, a.z), float2(b.x, b.z), prism, boundary);
            if (edge < 0) { continue; }

            uint slot = atomic_fetch_add_explicit(
                &counters[tile.counterBase + COUNTER_CUTS], 1u, memory_order_relaxed);
            if (slot >= tile.cutCapacity) {
                atomic_fetch_max_explicit(
                    &counters[tile.counterBase + COUNTER_OVERFLOW], 1u, memory_order_relaxed);
                continue;
            }
            CutEdge out;
            out.a = a;
            out.b = b;
            out.boundaryEdge = uint(edge);
            outCutEdges[tile.cutBase + slot] = out;
        }
    }

    kernel void \(functionName)(
        device const PackedVertex *sourceVertices [[buffer(\(Slot.sourceVertices))]],
        device const uint *sourceIndices          [[buffer(\(Slot.sourceIndices))]],
        constant Tile &tile                       [[buffer(\(Slot.tile))]],
        constant Prism &prism                     [[buffer(\(Slot.prism))]],
        device const float2 *boundary             [[buffer(\(Slot.boundary))]],
        device const Piece *pieces                [[buffer(\(Slot.pieces))]],
        device const float4 *pieceEdges           [[buffer(\(Slot.pieceEdges))]],
        device const uchar *grid                  [[buffer(\(Slot.grid))]],
        device PackedVertex *outVertices          [[buffer(\(Slot.outVertices))]],
        device uint *outIndices                   [[buffer(\(Slot.outIndices))]],
        device CutEdge *outCutEdges               [[buffer(\(Slot.outCutEdges))]],
        device atomic_uint *counters              [[buffer(\(Slot.counters))]],
        uint tid [[thread_position_in_grid]]
    ) {
        if (tid >= tile.triangleCount) { return; }

        ClipVertex triangle[3];
        for (uint k = 0; k < 3; ++k) {
            PackedVertex source = sourceVertices[sourceIndices[tid * 3 + k]];
            triangle[k].position = float3(source.position);
            triangle[k].normal = float3(source.normal);
            triangle[k].uv = float2(source.uv);
        }

        float2 a = float2(triangle[0].position.x, triangle[0].position.z);
        float2 b = float2(triangle[1].position.x, triangle[1].position.z);
        float2 c = float2(triangle[2].position.x, triangle[2].position.z);
        float2 lower = min(a, min(b, c));
        float2 upper = max(a, max(b, c));

        // Wholly outside the outline's extent.
        if (upper.x < prism.lowerBound.x || lower.x > prism.upperBound.x
            || upper.y < prism.lowerBound.y || lower.y > prism.upperBound.y) {
            return;
        }

        // The outline misses this triangle entirely, so it cannot span both sides of it: one corner
        // decides whether the whole thing is kept or dropped. This is the path almost every triangle
        // takes.
        if (!mayCrossOutline(lower, upper, prism, grid)) {
            if (!prismContains(a, prism, boundary)) { return; }
            emit(triangle, 3, tile, outVertices, outIndices, counters);
            return;
        }

        // Wholly inside, but close enough to the outline that the grid could not tell.
        if (prismContains(a, prism, boundary)
            && prismContains(b, prism, boundary)
            && prismContains(c, prism, boundary)) {
            emit(triangle, 3, tile, outVertices, outIndices, counters);
            return;
        }

        for (uint p = 0; p < prism.pieceCount; ++p) {
            Piece piece = pieces[p];
            if (prism.pieceCount > 1) {
                if (piece.upperBound.x < lower.x || piece.lowerBound.x > upper.x
                    || piece.upperBound.y < lower.y || piece.lowerBound.y > upper.y) {
                    continue;
                }
            }

            ClipVertex polygon[MAX_POLYGON];
            polygon[0] = triangle[0];
            polygon[1] = triangle[1];
            polygon[2] = triangle[2];
            uint count = 3;

            bool overflowed = false;
            bool survives = clipAgainstPiece(polygon, count, piece, pieceEdges, overflowed);
            if (overflowed) {
                // The whole tile goes back to the CPU, so there is no point finishing it here.
                atomic_fetch_max_explicit(
                    &counters[tile.counterBase + COUNTER_OVERFLOW], 1u, memory_order_relaxed);
                return;
            }
            if (!survives) { continue; }

            // Only the clipped path can produce a cut, and the outline is tested rather than the
            // piece, so the interior splits a concave outline is broken into do not become walls.
            collectCutEdges(polygon, count, tile, prism, boundary, outCutEdges, counters);
            emit(polygon, count, tile, outVertices, outIndices, counters);
        }
    }
    """
}
