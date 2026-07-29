import Foundation
import simd

/// The ladder of elevations a terraced chunk is cut to.
///
/// Fixed once and then held, which is the whole reason this is a value rather than something derived
/// per step. A pan slides new ground under the outline, and levels re-measured against whatever is
/// currently on screen would re-cut every step in the model at once — the same failure the wall
/// texture's vertical reference, the elevation baseline, and `InkImagery`'s tonal range all avoid by
/// freezing at load.
struct TerraceBands: Equatable {
    /// Vertical spacing between steps, in diorama meters.
    var step: Float
    /// Added to a height before the ladder is measured, so levels can land on multiples of a real
    /// elevation rather than on multiples above the chunk's own floor.
    var offset: Float
    /// Which rung the palette's first colour stands for.
    var firstBand: Int
    /// How many rungs the palette spans.
    var count: Int

    /// A ladder dividing a chunk's own relief into a fixed number of steps.
    init?(dividing lower: Float, _ upper: Float, into count: Int) {
        guard count > 0, upper > lower else { return nil }
        // One extra rung of headroom, so ground that pans in a little higher than anything measured
        // at load still gets its own colour instead of merging into the top band.
        self.step = (upper - lower) / Float(count)
        self.offset = 0
        self.firstBand = Int((lower / step).rounded(.down))
        self.count = count
    }

    /// A ladder on multiples of a real elevation, the way a contour map is drawn.
    ///
    /// - Parameters:
    ///   - meters: Spacing in real elevation meters.
    ///   - elevationScale: Diorama meters of height per real meter.
    ///   - baselineElevation: The real elevation diorama Y = 0 stands for.
    ///   - lower: The lowest ground the palette has to cover.
    ///   - upper: The highest.
    init?(
        everyMeters meters: Float,
        elevationScale: Float,
        baselineElevation: Float,
        lower: Float,
        upper: Float
    ) {
        guard meters > 0, elevationScale > 0, upper > lower else { return nil }
        self.step = meters * elevationScale
        self.offset = baselineElevation * elevationScale
        self.firstBand = Int(((lower + offset) / step).rounded(.down))
        let last = Int(((upper + offset) / step).rounded(.down))
        self.count = max(1, last - firstBand + 1)
    }

    /// Which rung a height sits on, unclamped.
    func rung(of y: Float) -> Int {
        Int(((y + offset) / step).rounded(.down))
    }

    /// The height a rung's flat top sits at.
    func level(ofRung rung: Int) -> Float {
        Float(rung) * step - offset
    }

    /// Where in the palette a rung falls, in `0..<count`.
    ///
    /// Clamped rather than extended, because panning is unbounded: ground far below or far above
    /// anything the chunk held at load still has to be painted something, and running off the end of
    /// the palette is the one thing it must not do.
    func paletteIndex(ofRung rung: Int) -> Int {
        min(max(rung - firstBand, 0), count - 1)
    }
}

/// Cuts a chunk's smooth surface into stacked flat steps.
///
/// The quantization is per vertex, which keeps the source topology intact and makes the whole thing a
/// pass over buffers rather than a re-triangulation — the same reason a pan is a buffer write. What
/// falls out of that is worth stating because it is what makes the result cheap *and* crisp:
///
/// - **A triangle whose three vertices land on one rung is exactly horizontal**, so its normal is
///   exactly `+Y` and never has to be computed. That is most of the surface, and it is why the
///   plateaus shade perfectly evenly instead of carrying the terrain's old gradients.
/// - **A triangle spanning rungs is the riser**, and it is always one grid cell wide however gentle
///   the slope, because quantization collapses everything between two rungs onto the lower one. So
///   the step reads as a step at any gradient rather than as a ramp on shallow ground.
///
/// Risers are emitted with their own vertices so they can take a face normal and a colour of their
/// own; plateaus share the source's vertices and its indices wholesale. Both go into one mesh with
/// one material, and the two are told apart by which row of the palette strip they sample.
enum TerraceGeometry {
    /// Which row of the palette strip a vertex reads.
    ///
    /// Two rows rather than two materials, so the whole terraced surface stays one mesh and one draw.
    /// The values are texel centres of a four-row strip: RealityKit measures V upwards from the
    /// bottom of the image, which is also the direction `CGContext` fills it, so the lower half of
    /// the strip is the lower value here.
    static let plateauRow: Float = 0.25
    static let riserRow: Float = 0.75

    /// Horizontal texture coordinate for a palette entry.
    static func paletteU(_ index: Int, count: Int) -> Float {
        guard count > 0 else { return 0.5 }
        return (Float(index) + 0.5) / Float(count)
    }

    /// The vertical span of a chunk's surface, which is what an automatic ladder is divided over.
    static func relief(of positions: [SIMD3<Float>]) -> (lower: Float, upper: Float)? {
        guard !positions.isEmpty else { return nil }
        var lower = Float.greatestFiniteMagnitude
        var upper = -Float.greatestFiniteMagnitude
        for position in positions {
            lower = min(lower, position.y)
            upper = max(upper, position.y)
        }
        guard upper > lower else { return nil }
        return (lower, upper)
    }

    /// Builds the stepped top surface.
    ///
    /// - Parameters:
    ///   - surface: The chunk's clipped top-surface buffers, as re-sampled by whatever pan is in
    ///     effect.
    ///   - bands: The ladder to cut to.
    ///   - mesh: Rewritten from empty; reused between steps so a pan does not reallocate it.
    static func buildSurface(
        from surface: TerrainSolidGenerator.Buffers,
        bands: TerraceBands,
        into mesh: inout IndexedMesh
    ) {
        mesh.removeAll()
        let positions = surface.positions
        guard !positions.isEmpty, surface.indices.count >= 3 else { return }

        mesh.reserve(vertices: positions.count, indices: surface.indices.count)

        // Every source vertex, dropped to its rung. Some are used by no plateau triangle — a vertex
        // surrounded entirely by risers — which costs a little buffer and draws nothing.
        var rungs = [Int](repeating: 0, count: positions.count)
        for index in positions.indices {
            let rung = bands.rung(of: positions[index].y)
            rungs[index] = rung
            let u = paletteU(bands.paletteIndex(ofRung: rung), count: bands.count)
            mesh.append(
                position: SIMD3(positions[index].x, bands.level(ofRung: rung), positions[index].z),
                normal: SIMD3(0, 1, 0),
                uv: SIMD2(u, plateauRow)
            )
        }

        var risers: [UInt32] = []
        var flats: [UInt32] = []
        flats.reserveCapacity(surface.indices.count)

        var cursor = 0
        while cursor + 2 < surface.indices.count {
            let a = surface.indices[cursor]
            let b = surface.indices[cursor + 1]
            let c = surface.indices[cursor + 2]
            cursor += 3

            let ra = rungs[Int(a)]
            let rb = rungs[Int(b)]
            let rc = rungs[Int(c)]
            if ra == rb, rb == rc {
                flats.append(a)
                flats.append(b)
                flats.append(c)
            } else {
                risers.append(a)
                risers.append(b)
                risers.append(c)
            }
        }

        mesh.appendIndices(flats)

        // Risers carry their own copies so they can hold a face normal and the riser row of the
        // palette without dragging the plateaus they join off flat.
        let u = { (rung: Int) in paletteU(bands.paletteIndex(ofRung: rung), count: bands.count) }
        var index = 0
        while index + 2 < risers.count {
            let ia = Int(risers[index])
            let ib = Int(risers[index + 1])
            let ic = Int(risers[index + 2])
            index += 3

            let pa = SIMD3(positions[ia].x, bands.level(ofRung: rungs[ia]), positions[ia].z)
            let pb = SIMD3(positions[ib].x, bands.level(ofRung: rungs[ib]), positions[ib].z)
            let pc = SIMD3(positions[ic].x, bands.level(ofRung: rungs[ic]), positions[ic].z)

            let cross = simd_cross(pb - pa, pc - pa)
            let length = simd_length(cross)
            // A clipped sliver can quantize to no area at all. Facing up is the harmless answer:
            // the triangle draws nothing either way.
            let normal = length > 0 ? cross / length : SIMD3<Float>(0, 1, 0)

            // The riser belongs to the step above it — it is the side of that slab, the way the edge
            // of a sheet in a stacked model belongs to the sheet rather than to the one below.
            let uv = SIMD2(u(max(rungs[ia], max(rungs[ib], rungs[ic]))), riserRow)
            let va = mesh.append(position: pa, normal: normal, uv: uv)
            let vb = mesh.append(position: pb, normal: normal, uv: uv)
            let vc = mesh.append(position: pc, normal: normal, uv: uv)
            mesh.appendTriangle(va, vb, vc)
        }
    }

    /// Builds cut walls whose top edge follows the stepped surface rather than the smooth terrain.
    ///
    /// Not optional decoration. Quantizing rounds down, so a wall left alone stands up to a full step
    /// proud of the surface it is supposed to meet, and the chunk gets a ragged lip of strata all the
    /// way around its rim. The wall's top vertices are the same points as the surface's border
    /// vertices, so putting them through the same ladder closes it exactly.
    ///
    /// - Parameters:
    ///   - walls: The chunk's wall buffers. `TerrainSolidGenerator` emits each quad's vertices as
    ///     top, bottom, top, bottom, so the even ones are the rim — the same convention `resample`
    ///     relies on.
    ///   - bands: The ladder to cut to.
    ///   - baseDepth: How far the chunk hangs below Y = 0.
    ///   - wallHeight: The vertical span the wall texture is normalized against.
    ///   - mesh: Rewritten from empty.
    static func buildWalls(
        from walls: TerrainSolidGenerator.Buffers,
        bands: TerraceBands,
        baseDepth: Float,
        wallHeight: Float,
        into mesh: inout IndexedMesh
    ) {
        mesh.removeAll()
        guard !walls.positions.isEmpty, !walls.indices.isEmpty else { return }
        mesh.reserve(vertices: walls.positions.count, indices: walls.indices.count)

        for index in walls.positions.indices {
            var position = walls.positions[index]
            var uv = walls.uvs[index]
            if index % 2 == 0 {
                position.y = max(bands.level(ofRung: bands.rung(of: position.y)), -baseDepth)
                uv.y = wallHeight > 0
                    ? min(max((position.y + baseDepth) / wallHeight, 0), 1)
                    : 0
            }
            mesh.append(position: position, normal: walls.normals[index], uv: uv)
        }
        mesh.appendIndices(walls.indices)
    }
}
