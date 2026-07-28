import CoreGraphics
import Foundation
import Testing
import simd
@testable import Maquette

/// The ink effect draws its outlines as real triangles, because RealityKit exposes no cross-platform
/// post-process to detect edges with — so where a screen-space treatment would ask the framebuffer,
/// this asks the mesh, and everything it can get wrong is geometric.
///
/// Two failures matter more than the rest, and neither shows up in a vertex count. A border edge that
/// should have welded draws an ink line down the middle of the surface, so the borders are measured
/// against the outline's own perimeter rather than counted. And a crease threshold that admits too
/// much turns the chunk solid black, so the dihedral test is checked at both ends.
@Suite("Ink Effect Tests")
struct InkTests {

    // MARK: - Fixtures

    /// A single-tile height field with a cone rising toward the center.
    private func coneHeightField(resolution: Int = 32, extent: Float = 1.0) -> TerrainHeightField {
        var values: [Float] = []
        for row in 0..<resolution {
            for col in 0..<resolution {
                let dx = Float(col) / Float(resolution - 1) - 0.5
                let dz = Float(row) / Float(resolution - 1) - 0.5
                let distance = sqrt(dx * dx + dz * dz)
                values.append(100 + max(0, 1 - distance * 2) * 200)
            }
        }
        return TerrainHeightField(
            grids: [ElevationGrid(width: resolution, height: resolution, values: values)],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(extent, extent),
            elevationScale: 0.001
        )
    }

    /// A flat unit quad as two triangles, wound counter-clockwise seen from above.
    private var quad: (positions: [SIMD3<Float>], indices: [UInt32]) {
        (
            positions: [
                SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 1), SIMD3(0, 0, 1),
            ],
            indices: [0, 1, 2, 0, 2, 3]
        )
    }

    private func length(of segments: [ContourExtractor.Segment]) -> Float {
        segments.reduce(0) { $0 + simd_length($1.b - $1.a) }
    }

    private func horizontalLength(of segments: [ContourExtractor.Segment]) -> Float {
        segments.reduce(0) { total, segment in
            let delta = segment.b - segment.a
            return total + simd_length(SIMD2(delta.x, delta.z))
        }
    }

    // MARK: - Edges

    @Test("A quad's outer edges are borders and its diagonal is not")
    func quadBorders() {
        let quad = quad
        var edges = MeshEdges(positions: quad.positions, indices: quad.indices, tolerance: 1e-5)
        let borders = edges.borders(in: quad.positions)

        #expect(borders.count == 4, "A quad has four outer edges, found \(borders.count)")
        // The diagonal is shared, so the perimeter is 4 and not 4 + √2.
        #expect(abs(length(of: borders) - 4) < 1e-4)
    }

    @Test("Coincident vertices weld rather than opening a false border")
    func coincidentVerticesWeld() {
        // The same quad, but the second triangle carries its own copies of the two shared corners —
        // which is exactly what `TerrainSolidGenerator` emits for a boundary-clipped cell, since a
        // clipped cell appends its own vertices instead of reusing the grid's.
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 1),
            SIMD3(0, 0, 0), SIMD3(1, 0, 1), SIMD3(0, 0, 1),
        ]
        var edges = MeshEdges(positions: positions, indices: [0, 1, 2, 3, 4, 5], tolerance: 1e-5)
        let borders = edges.borders(in: positions)

        #expect(borders.count == 4, "The shared diagonal should weld, found \(borders.count) borders")
    }

    @Test("A fold is a crease past its angle and not before it")
    func foldIsACrease() {
        // A roof: two slopes at 45° meeting along a ridge at x = 1, which is a 90° fold. Shaped like
        // terrain rather than like a box on purpose — the weld is horizontal only, so two vertices
        // stacked at one `(x, z)` become one point, which is right for a height field and would
        // quietly collapse a fixture built as a vertical wall.
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, 1),
            SIMD3(1, 1, 0), SIMD3(1, 1, 1),
            SIMD3(2, 0, 0), SIMD3(2, 0, 1),
        ]
        let indices: [UInt32] = [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4]
        var edges = MeshEdges(positions: positions, indices: indices, tolerance: 1e-5)

        let steep = edges.creases(in: positions, minimumAngle: 80 * .pi / 180)
        let gentle = edges.creases(in: positions, minimumAngle: 100 * .pi / 180)

        #expect(steep.count == 1, "The ridge is the one 90° fold, found \(steep.count) creases")
        #expect(gentle.isEmpty, "A 90° fold should not be a crease at a 100° threshold")
    }

    @Test("A crease budget bounds the drawing and spreads it over the chunk")
    func creaseBudgetIsBoundedAndSpread() {
        // Rough on one side of the chunk, smooth on the other — which is what a pan produces in
        // practice, and the case a fixed angle handles worst: the rough side inks until it is solid
        // and the smooth side is left bare, so the same chunk reads as two different drawings.
        let boundary = DioramaBoundary.make(shape: .rectangular(width: 1, depth: 1),
                                            extent: SIMD2(1.0, 1.0))
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: halfRoughHeightField(),
            boundary: boundary,
            baseDepth: 0.1,
            includesWalls: false,
            includesBottom: false,
            resolution: 96
        )
        let positions = geometry.top.positions
        var edges = MeshEdges(positions: positions, indices: geometry.top.indices, tolerance: 1e-5)
        let angle: Float = 30 * .pi / 180

        let unbounded = edges.creases(in: positions, minimumAngle: angle)
        let budgeted = edges.creases(in: positions, minimumAngle: angle, density: 0.02)

        #expect(!unbounded.isEmpty, "The fixture should have creases to budget")
        #expect(budgeted.count < unbounded.count,
                "A budget of 2% left \(budgeted.count) of \(unbounded.count) creases")

        // The half the terrain is rough over must not take the whole budget: a bound that is only a
        // cap would leave the drawing exactly as lopsided, just shorter.
        func roughShare(of segments: [ContourExtractor.Segment]) -> Float {
            guard !segments.isEmpty else { return 0 }
            let rough = segments.filter { ($0.a.x + $0.b.x) / 2 > 0 }
            return Float(rough.count) / Float(segments.count)
        }
        #expect(roughShare(of: unbounded) > 0.9,
                "The fixture's creases should start lopsided, at \(roughShare(of: unbounded))")
        #expect(roughShare(of: budgeted) < roughShare(of: unbounded),
                "The budget should have moved lines onto the smooth half, still at \(roughShare(of: budgeted))")
    }

    /// A height field that is jagged over its eastern half and gently sloped over its western.
    private func halfRoughHeightField(resolution: Int = 64) -> TerrainHeightField {
        var values: [Float] = []
        for row in 0..<resolution {
            for col in 0..<resolution {
                let x = Float(col) / Float(resolution - 1)
                if x > 0.5 {
                    values.append(100 + Float((row + col) % 2) * 300)
                } else {
                    values.append(100 + x * 40 + Float(row) / Float(resolution) * 10)
                }
            }
        }
        return TerrainHeightField(
            grids: [ElevationGrid(width: resolution, height: resolution, values: values)],
            tilePositions: [(x: 0, y: 0)],
            extent: SIMD2(1.0, 1.0),
            elevationScale: 0.001
        )
    }

    @Test("A flat surface has no creases at any useful angle")
    func flatSurfaceHasNoCreases() {
        let quad = quad
        var edges = MeshEdges(positions: quad.positions, indices: quad.indices, tolerance: 1e-5)
        #expect(edges.creases(in: quad.positions, minimumAngle: 1 * .pi / 180).isEmpty)
    }

    @Test("The chunk's border traces its outline and nothing else")
    func chunkBorderMatchesOutline() {
        // The invariant that actually defines the rim, and the one a vertex count cannot see. The
        // clipped top surface holds coincident-but-distinct vertices along every boundary cell's
        // seam; if those fail to weld, each seam becomes a border and the total runs far past the
        // outline's own perimeter — which on screen is an ink cage drawn over the whole chunk.
        let boundary = DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0))
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: boundary,
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 64
        )

        var edges = MeshEdges(
            positions: geometry.top.positions,
            indices: geometry.top.indices,
            tolerance: 1e-5
        )
        let borders = edges.borders(in: geometry.top.positions)

        var perimeter: Float = 0
        for index in boundary.vertices.indices {
            let next = boundary.vertices[(index + 1) % boundary.vertices.count]
            perimeter += simd_length(next - boundary.vertices[index])
        }

        let traced = horizontalLength(of: borders)
        #expect(abs(traced - perimeter) / perimeter < 0.02,
                "Border traced \(traced) against an outline of \(perimeter)")
    }

    // MARK: - Corners

    @Test("A square's corners are inked and a circle's are not")
    func cornerDetection() {
        let square = DioramaBoundary.make(shape: .rectangular(width: 1, depth: 1), extent: SIMD2(1.0, 1.0))
        let circle = DioramaBoundary.make(shape: .circular, extent: SIMD2(1.0, 1.0))
        let threshold: Float = 25 * .pi / 180

        let squareCorners = InkGeometry.cornerIndices(of: square.vertices, minimumAngle: threshold)
        let circleCorners = InkGeometry.cornerIndices(of: circle.vertices, minimumAngle: threshold)

        #expect(squareCorners.count == 4, "A square has four corners, found \(squareCorners.count)")
        // A circle is drawn as many short segments, each turning a few degrees. Inking them all would
        // turn the block into a solid drum of ink rather than a cylinder, which has no corners at all.
        #expect(circleCorners.isEmpty, "A circle should have no inked corners, found \(circleCorners.count)")
    }

    @Test("A boundary vertex resolves to the surface vertex standing on it")
    func cornersFindTheSurface() {
        let boundary = DioramaBoundary.make(shape: .rectangular(width: 1, depth: 1), extent: SIMD2(1.0, 1.0))
        let geometry = TerrainSolidGenerator.buildGeometry(
            heightField: coneHeightField(),
            boundary: boundary,
            baseDepth: 0.1,
            includesWalls: true,
            includesBottom: true,
            resolution: 64
        )

        let corners = InkGeometry.cornerIndices(of: boundary.vertices, minimumAngle: 25 * .pi / 180)
        let points = corners.map { boundary.vertices[$0] }
        let matched = InkGeometry.nearestVertices(to: points, in: geometry.top.positions)

        #expect(matched.count == points.count)
        for (point, index) in zip(points, matched) {
            let found = geometry.top.positions[index]
            // The surface was clipped *to* the outline, so the boundary's own vertices are vertices
            // of it — the match is exact rather than nearby.
            #expect(simd_length(SIMD2(found.x, found.z) - point) < 1e-4)
        }
    }

    // MARK: - Tubes

    @Test("A tube is drawn at the requested width and spans its segment")
    func tubeDimensions() {
        var mesh = IndexedMesh()
        let radius: Float = 0.02
        InkGeometry.addTubes(
            [ContourExtractor.Segment(a: SIMD3(0, 0, 0), b: SIMD3(1, 0, 0))],
            radius: radius,
            into: &mesh
        )

        #expect(mesh.vertices.count == 8)
        #expect(mesh.indices.count == 36, "Four sides and two caps is twelve triangles")

        let bounds = mesh.bounds
        // Square section, so the tube is `2 * radius` across in both directions across its own axis.
        #expect(abs((bounds.max.y - bounds.min.y) - 2 * radius) < 1e-5)
        #expect(abs((bounds.max.z - bounds.min.z) - 2 * radius) < 1e-5)
        // And extended by a radius at each end, so consecutive segments overlap into their corner.
        #expect(abs((bounds.max.x - bounds.min.x) - (1 + 2 * radius)) < 1e-5)
    }

    @Test("A vertical tube keeps its width")
    func verticalTubeDimensions() {
        // The reference axis has to swap for a near-vertical segment, and the vertical lines down a
        // block's corners are exactly that case — a degenerate cross product here would collapse the
        // tube to nothing.
        var mesh = IndexedMesh()
        let radius: Float = 0.02
        InkGeometry.addTubes(
            [ContourExtractor.Segment(a: SIMD3(0.3, 0.2, -0.4), b: SIMD3(0.3, -0.1, -0.4))],
            radius: radius,
            into: &mesh
        )

        let bounds = mesh.bounds
        #expect(abs((bounds.max.x - bounds.min.x) - 2 * radius) < 1e-5)
        #expect(abs((bounds.max.z - bounds.min.z) - 2 * radius) < 1e-5)
    }

    @Test("A degenerate segment draws nothing")
    func degenerateSegment() {
        var mesh = IndexedMesh()
        InkGeometry.addTubes(
            [ContourExtractor.Segment(a: SIMD3(1, 1, 1), b: SIMD3(1, 1, 1))],
            radius: 0.01,
            into: &mesh
        )
        #expect(mesh.isEmpty)
    }

    // MARK: - Imagery

    /// An image built pixel by pixel.
    private func image(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> SIMD3<UInt8>
    ) throws -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let colour = pixel(x, y)
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = colour.x
                pixels[offset + 1] = colour.y
                pixels[offset + 2] = colour.z
            }
        }

        let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        return try #require(image)
    }

    /// A grey gradient running from `low` to `high` across the width.
    private func gradient(width: Int, height: Int, low: Int = 0, high: Int = 255) throws -> CGImage {
        try image(width: width, height: height) { x, _ in
            let value = UInt8(low + x * (high - low) / max(1, width - 1))
            return SIMD3(repeating: value)
        }
    }

    /// Every distinct RGB triple in an image.
    private func colours(of image: CGImage) throws -> Set<SIMD3<UInt8>> {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drew)

        var found: Set<SIMD3<UInt8>> = []
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            found.insert(SIMD3(pixels[offset], pixels[offset + 1], pixels[offset + 2]))
        }
        return found
    }

    @Test("Posterizing reduces a gradient to the requested number of levels")
    func posterizeQuantizes() throws {
        let source = try gradient(width: 64, height: 8)
        #expect(try colours(of: source).count > 16, "The fixture should be a gradient to begin with")

        let flattened = try InkImagery.posterize(
            source,
            recipe: InkImagery.Recipe(patchSize: 4, levels: 4, saturation: 1)
        )
        let found = try colours(of: flattened.image)

        // Grey in, grey out at saturation 1, so every result sits on the band grid's diagonal.
        #expect(found.count <= 4, "Expected at most four levels, found \(found.count)")
        #expect(found.contains(SIMD3(0, 0, 0)), "The darkest band should reach black")
        #expect(found.contains(SIMD3(255, 255, 255)), "The brightest band should reach white")
    }

    @Test("Posterizing flattens each patch to one colour")
    func posterizeFlattensPatches() throws {
        // Sixteen levels over 64 columns would otherwise leave four columns per band; a patch of 64
        // spans the whole gradient, so the whole image has to come back as its single average.
        let source = try gradient(width: 64, height: 8)
        let flattened = try InkImagery.posterize(
            source,
            recipe: InkImagery.Recipe(patchSize: 64, levels: 16, saturation: 1)
        )
        #expect(try colours(of: flattened.image).count == 1)
    }

    @Test("Saturation leaves grey alone")
    func posterizeSaturates() throws {
        let source = try gradient(width: 8, height: 8)
        let flattened = try InkImagery.posterize(
            source,
            recipe: InkImagery.Recipe(patchSize: 8, levels: 32, saturation: 2)
        )
        // The fixture is grey, which has no distance from its own grey to scale.
        for colour in try colours(of: flattened.image) {
            #expect(colour.x == colour.y && colour.y == colour.z)
        }
    }

    @Test("A narrow band of tone is spread across the levels")
    func posterizeStretchesTheRange() throws {
        // Aerial imagery of ordinary ground occupies a fraction of the scale, and this is the whole
        // reason the range is measured rather than assumed: banded against black-to-white, every
        // pixel here lands in one band and the chunk comes out as a single flat slab.
        let source = try gradient(width: 64, height: 8, low: 100, high: 140)
        let flattened = try InkImagery.posterize(
            source,
            recipe: InkImagery.Recipe(patchSize: 4, levels: 4, saturation: 1)
        )
        let found = try colours(of: flattened.image)

        #expect(found.count > 1, "A forty-value range should still band, found \(found.count) colour")
        #expect(found.contains(SIMD3(0, 0, 0)))
        #expect(found.contains(SIMD3(255, 255, 255)))
        #expect(abs(flattened.tones.low - 100.0 / 255) < 0.05)
        #expect(abs(flattened.tones.high - 140.0 / 255) < 0.05)
    }

    @Test("A reused tonal range holds the palette still")
    func posterizeReusesTones() throws {
        // What a roll does: the same ground, brighter, because the tiles that arrived are lit
        // differently. Measured afresh it would renormalize and repaint every band at once; measured
        // once and reused, brighter ground reads as brighter.
        let dark = try gradient(width: 64, height: 8, low: 40, high: 90)
        let bright = try gradient(width: 64, height: 8, low: 140, high: 190)
        let recipe = InkImagery.Recipe(patchSize: 4, levels: 4, saturation: 1)

        let first = try InkImagery.posterize(dark, recipe: recipe)
        let held = try InkImagery.posterize(bright, recipe: recipe, tones: first.tones)
        let remeasured = try InkImagery.posterize(bright, recipe: recipe)

        #expect(held.tones == first.tones, "The range passed in should come back unchanged")
        // Held against the dark image's range, brighter ground saturates to white rather than
        // banding across the full grid as it would if it had set the range itself.
        #expect(try colours(of: held.image) == [SIMD3(255, 255, 255)])
        #expect(try colours(of: remeasured.image).count > 1)
    }

    @Test("Near-grey ground does not come back speckled")
    func posterizeDoesNotSpeckle() throws {
        // The regression that made the first build unusable. Quantizing red, green and blue on their
        // own grids splits a near-grey patch whose channels straddle a band edge into a fully
        // saturated colour, so even ground turns to confetti. Sitting the fixture right on a band
        // edge — 128 against boundaries at 42, 128 and 213 for four levels — is what provokes it.
        let jitter: [SIMD3<UInt8>] = [
            SIMD3(125, 128, 131), SIMD3(131, 127, 125),
            SIMD3(128, 131, 126), SIMD3(126, 125, 130),
        ]
        let source = try image(width: 16, height: 16) { x, y in jitter[(x &+ y * 3) % jitter.count] }
        let flattened = try InkImagery.posterize(
            source,
            // An explicit range, because auto-levels would otherwise stretch six values of jitter
            // across the whole scale and provoke exactly the speckle this is measuring.
            recipe: InkImagery.Recipe(patchSize: 1, levels: 4, saturation: 1.35),
            tones: InkImagery.Tones(low: 0, high: 1)
        )

        for colour in try colours(of: flattened.image) {
            let spread = Int(colour.max()) - Int(colour.min())
            #expect(spread <= 16, "Near-grey came back as \(colour), a spread of \(spread)")
        }
    }
}
