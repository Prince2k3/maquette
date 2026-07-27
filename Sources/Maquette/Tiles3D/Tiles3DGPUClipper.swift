import Foundation
import Metal
import RealityKit
import os
import simd

/// Runs the outline clip on the GPU, a whole pan step's worth of tiles at a time.
///
/// The clip is the last large cost in a pan step — measured at roughly 41 ms of an 85 ms step on the
/// Pan 3D preset — and it is per-triangle work with no dependency between triangles, which is the
/// shape a compute kernel exists for. `Tiles3DClipper` stays as the definition of the algorithm and
/// as the fallback: this cuts the same geometry the same way, and hands anything it cannot finish
/// back to it.
///
/// Three things shape the design.
///
/// **Source geometry is uploaded once per tile, not once per step.** A tile's vertices in diorama
/// space do not change when the outline moves; only the outline does. The CPU clipper re-bakes each
/// tile's placement into a fresh vertex array on every re-cut, and that array is exactly what the
/// GPU needs resident anyway, so uploading it once removes work from both sides. A tile pays for its
/// upload the first time the outline reaches it and never again.
///
/// **Output size is not known in advance,** so each thread reserves its own room with an atomic add
/// into a per-tile region of a shared scratch buffer. Triangles therefore land in whatever order the
/// hardware produces rather than in source order. That is invisible in the result — a mesh has no
/// preferred triangle order — and the counts still come out identical, which is what makes a matched
/// A/B against the CPU path meaningful.
///
/// **A bounded thread-local polygon is the price of running on a GPU at all.** Sutherland-Hodgman
/// needs scratch polygons per thread, and unlike the CPU's reused arrays that storage is paid for by
/// every thread whether it clips or not. So it is capped, and a tile that exceeds the cap sets an
/// overflow flag and is re-cut exactly on the CPU. Nothing is lost; occasionally something is done
/// twice.
///
/// **The whole batch goes out as one dispatch**, which is why the tiles share an arena rather than
/// each holding its own buffer. Encoding a dispatch per tile meant rebinding two buffers and copying
/// a `Tile` through the encoder ~180 times a step; with one dispatch the per-tile data is a buffer
/// the kernel indexes instead of encoder state it replays.
@MainActor
final class Tiles3DGPUClipper {
    /// What the kernel made of one tile.
    ///
    /// The buffers point into scratch that the next batch overwrites, so a caller has to consume
    /// them before returning from its handler — which is what writing them into a `LowLevelMesh`
    /// does anyway.
    enum Outcome {
        case clipped(
            vertices: UnsafeBufferPointer<Tiles3DVertex>,
            indices: UnsafeBufferPointer<UInt32>,
            cutEdges: [Tiles3DCutEdge],
            bounds: BoundingBox
        )
        /// Nothing of this tile survives the outline.
        case empty
        /// The GPU could not finish this tile. The caller has to run the CPU clip for it.
        case unresolved
    }

    /// Vertices of output room reserved per source triangle, before any growth.
    ///
    /// A triangle kept whole produces exactly three; only the ones the outline actually crosses
    /// produce more, and a rim tile is mostly whole triangles.
    private static let vertexAllowance = 4
    /// Index room per source triangle. A fan over `n` vertices is `3(n - 2)` indices, so this stays
    /// ahead of `vertexAllowance` for every polygon the cap permits.
    private static let indexAllowance = 8
    /// Room every tile gets regardless of size.
    ///
    /// The per-triangle allowances are averages, and an average needs something to average over: a
    /// tile of two triangles that both straddle the outline exceeds four vertices apiece and falls
    /// back, where a tile of two thousand absorbs the same excess without noticing. A floor costs a
    /// few kilobytes of scratch and takes the smallest tiles off the fallback path entirely.
    private static let minimumVertexRoom = 64
    private static let minimumIndexRoom = 128
    /// The most output vertices one batch will hold before it is split and submitted in pieces.
    ///
    /// Purely a memory bound. A pan step's whole rim fits well inside it; this exists so a
    /// pathological step cannot ask for an unbounded allocation.
    private static let maximumBatchVertices = 1 << 20
    /// How far a tile's allowance may be grown before it is simply left to the CPU.
    private static let maximumGrowth = 8

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let threadsPerGroup: Int
    private let logger = Logger(subsystem: "com.maquette", category: "Tiles3DGPUClipper")

    /// Where one tile's placement-baked geometry sits in the arenas, until the tile is evicted.
    private final class Source {
        let vertices: Range<Int>
        let indices: Range<Int>
        let triangleCount: Int
        /// Multiplies the output allowances. Doubles whenever a cut overruns what it was given.
        var growth = 1

        init(vertices: Range<Int>, indices: Range<Int>, triangleCount: Int) {
            self.vertices = vertices
            self.indices = indices
            self.triangleCount = triangleCount
        }
    }

    private var sources: [String: Source] = [:]
    private let vertexArena: Arena
    private let indexArena: Arena

    private var boundaryBuffer: (any MTLBuffer)?
    private var piecesBuffer: (any MTLBuffer)?
    private var pieceEdgesBuffer: (any MTLBuffer)?
    private var gridBuffer: (any MTLBuffer)?
    private var prismUniforms = Tiles3DClipKernel.Prism(
        lowerBound: .zero, upperBound: .zero, gridCellScale: .zero, centroid: .zero,
        innerRadiusSquared: 0, outerRadiusSquared: 0, cutEdgeTolerance: 0,
        boundaryCount: 0, pieceCount: 0, gridResolution: 0
    )

    private var vertexScratch: (any MTLBuffer)?
    private var indexScratch: (any MTLBuffer)?
    private var cutEdgeScratch: (any MTLBuffer)?
    private var counterScratch: (any MTLBuffer)?
    private var tilesBuffer: (any MTLBuffer)?
    private var groupTilesBuffer: (any MTLBuffer)?

    /// Builds the device, queue and pipeline, or returns `nil` if any of it is unavailable.
    ///
    /// Compiling the kernel from source costs a fraction of a second, which is why this is created
    /// while tiles are still streaming rather than on the first pan.
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            return nil
        }
        do {
            let library = try device.makeLibrary(source: Tiles3DClipKernel.source, options: nil)
            guard let function = library.makeFunction(name: Tiles3DClipKernel.functionName) else {
                return nil
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            self.device = device
            self.queue = queue
            self.pipeline = pipeline
            // Each thread carries two scratch polygons and a side array, so a narrow threadgroup
            // keeps that within what the hardware can hold in registers.
            self.threadsPerGroup = max(1, min(pipeline.maxTotalThreadsPerThreadgroup, 64))
            self.vertexArena = Arena(
                device: device, stride: MemoryLayout<Tiles3DVertex>.stride
            )
            self.indexArena = Arena(device: device, stride: MemoryLayout<UInt32>.stride)
        } catch {
            return nil
        }
    }

    /// Forgets a tile's uploaded geometry, for when the tile itself is evicted.
    func discard(_ uri: String) {
        guard let source = sources.removeValue(forKey: uri) else { return }
        vertexArena.release(source.vertices)
        indexArena.release(source.indices)
    }

    // MARK: - Clipping

    /// Cuts a batch of tiles to the outline, reporting each one as its result is read back.
    ///
    /// The whole batch goes out as a single command buffer and is waited on once. Submitting per
    /// tile would pay a round trip a couple of hundred times a step, which is the cost this is meant
    /// to avoid rather than incur.
    func clip(
        _ jobs: [(uri: String, source: Tiles3DSourceGeometry)],
        to prism: BoundaryPrism,
        handling handler: (Int, Outcome) -> Void
    ) {
        guard uploadPrism(prism) else {
            for index in jobs.indices { handler(index, .unresolved) }
            return
        }

        var batch: [Entry] = []
        var vertexTotal = 0
        var indexTotal = 0
        var cutEdgeTotal = 0

        func flush() {
            guard !batch.isEmpty else { return }
            run(batch, vertices: vertexTotal, indices: indexTotal, cutEdges: cutEdgeTotal, handler: handler)
            batch.removeAll(keepingCapacity: true)
            vertexTotal = 0
            indexTotal = 0
            cutEdgeTotal = 0
        }

        for index in jobs.indices {
            let job = jobs[index]
            guard let source = source(for: job.uri, geometry: job.source) else {
                handler(index, .unresolved)
                continue
            }
            guard source.triangleCount > 0 else {
                handler(index, .empty)
                continue
            }
            guard source.growth <= Self.maximumGrowth else {
                handler(index, .unresolved)
                continue
            }

            let vertexRoom = max(
                Self.minimumVertexRoom, source.triangleCount * Self.vertexAllowance
            ) * source.growth
            let indexRoom = max(
                Self.minimumIndexRoom, source.triangleCount * Self.indexAllowance
            ) * source.growth
            let cutEdgeRoom = max(512, source.triangleCount / 2) * source.growth

            if vertexTotal + vertexRoom > Self.maximumBatchVertices { flush() }

            batch.append(Entry(
                jobIndex: index,
                uri: job.uri,
                source: source,
                tile: Tiles3DClipKernel.Tile(
                    triangleCount: UInt32(source.triangleCount),
                    vertexOffset: UInt32(source.vertices.lowerBound),
                    indexOffset: UInt32(source.indices.lowerBound),
                    vertexBase: UInt32(vertexTotal),
                    vertexCapacity: UInt32(vertexRoom),
                    indexBase: UInt32(indexTotal),
                    indexCapacity: UInt32(indexRoom),
                    cutBase: UInt32(cutEdgeTotal),
                    cutCapacity: UInt32(cutEdgeRoom),
                    counterBase: UInt32(batch.count * Tiles3DClipKernel.countersPerTile),
                    // Filled in when the batch is dispatched and the group layout is known.
                    firstGroup: 0
                )
            ))
            vertexTotal += vertexRoom
            indexTotal += indexRoom
            cutEdgeTotal += cutEdgeRoom
        }

        flush()
    }

    private struct Entry {
        let jobIndex: Int
        let uri: String
        let source: Source
        var tile: Tiles3DClipKernel.Tile
    }

    private func run(
        _ batch: [Entry],
        vertices vertexTotal: Int,
        indices indexTotal: Int,
        cutEdges cutEdgeTotal: Int,
        handler: (Int, Outcome) -> Void
    ) {
        // The batch goes out as one dispatch, so everything that used to be encoder state replayed
        // per tile becomes a buffer the kernel indexes. Tile boundaries are aligned to threadgroups
        // — a tile's triangles are rounded up to a whole number of groups — which is what lets a
        // thread find its tile with a lookup rather than a search. The padding is at most one group
        // short of full per tile, a few thousand idle threads in a dispatch of a hundred thousand.
        var tiles: [Tiles3DClipKernel.Tile] = []
        tiles.reserveCapacity(batch.count)
        var groupTiles: [UInt32] = []
        for (index, entry) in batch.enumerated() {
            var tile = entry.tile
            tile.firstGroup = UInt32(groupTiles.count)
            tiles.append(tile)
            let groups = (entry.source.triangleCount + threadsPerGroup - 1) / threadsPerGroup
            groupTiles.append(contentsOf: repeatElement(UInt32(index), count: groups))
        }

        guard !groupTiles.isEmpty,
            ensureScratch(
                vertices: vertexTotal, indices: indexTotal, cutEdges: cutEdgeTotal, tiles: batch.count
            ),
            upload(tiles, into: &tilesBuffer),
            upload(groupTiles, into: &groupTilesBuffer),
            let vertexScratch, let indexScratch, let cutEdgeScratch, let counterScratch,
            let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            for entry in batch { handler(entry.jobIndex, .unresolved) }
            return
        }

        let counters = counterScratch.contents()
            .bindMemory(to: UInt32.self, capacity: batch.count * Tiles3DClipKernel.countersPerTile)
        for tile in 0..<batch.count {
            let base = tile * Tiles3DClipKernel.countersPerTile
            counters[base + Tiles3DClipKernel.Counter.vertexCount] = 0
            counters[base + Tiles3DClipKernel.Counter.indexCount] = 0
            counters[base + Tiles3DClipKernel.Counter.cutEdgeCount] = 0
            counters[base + Tiles3DClipKernel.Counter.overflow] = 0
            // Minima start at the top of the ordering and maxima at the bottom, so the first value
            // written wins outright.
            for axis in 0..<3 {
                counters[base + Tiles3DClipKernel.Counter.bounds + axis] = .max
                counters[base + Tiles3DClipKernel.Counter.bounds + 3 + axis] = 0
            }
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(
            &prismUniforms,
            length: MemoryLayout<Tiles3DClipKernel.Prism>.stride,
            index: Tiles3DClipKernel.Slot.prism
        )
        encoder.setBuffer(vertexArena.buffer, offset: 0, index: Tiles3DClipKernel.Slot.sourceVertices)
        encoder.setBuffer(indexArena.buffer, offset: 0, index: Tiles3DClipKernel.Slot.sourceIndices)
        encoder.setBuffer(tilesBuffer, offset: 0, index: Tiles3DClipKernel.Slot.tiles)
        encoder.setBuffer(groupTilesBuffer, offset: 0, index: Tiles3DClipKernel.Slot.groupTiles)
        encoder.setBuffer(boundaryBuffer, offset: 0, index: Tiles3DClipKernel.Slot.boundary)
        encoder.setBuffer(piecesBuffer, offset: 0, index: Tiles3DClipKernel.Slot.pieces)
        encoder.setBuffer(pieceEdgesBuffer, offset: 0, index: Tiles3DClipKernel.Slot.pieceEdges)
        encoder.setBuffer(gridBuffer, offset: 0, index: Tiles3DClipKernel.Slot.grid)
        encoder.setBuffer(vertexScratch, offset: 0, index: Tiles3DClipKernel.Slot.outVertices)
        encoder.setBuffer(indexScratch, offset: 0, index: Tiles3DClipKernel.Slot.outIndices)
        encoder.setBuffer(cutEdgeScratch, offset: 0, index: Tiles3DClipKernel.Slot.outCutEdges)
        encoder.setBuffer(counterScratch, offset: 0, index: Tiles3DClipKernel.Slot.counters)

        encoder.dispatchThreadgroups(
            MTLSize(width: groupTiles.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1)
        )

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.error != nil {
            for entry in batch { handler(entry.jobIndex, .unresolved) }
            return
        }

        let vertexOut = vertexScratch.contents().bindMemory(
            to: Tiles3DVertex.self, capacity: vertexTotal
        )
        let indexOut = indexScratch.contents().bindMemory(to: UInt32.self, capacity: indexTotal)
        let cutEdgeOut = cutEdgeScratch.contents().bindMemory(
            to: Tiles3DClipKernel.CutEdge.self, capacity: cutEdgeTotal
        )

        for (tile, entry) in batch.enumerated() {
            let base = tile * Tiles3DClipKernel.countersPerTile
            let vertexCount = Int(counters[base + Tiles3DClipKernel.Counter.vertexCount])
            let indexCount = Int(counters[base + Tiles3DClipKernel.Counter.indexCount])
            let cutEdgeCount = Int(counters[base + Tiles3DClipKernel.Counter.cutEdgeCount])

            // The reservations are made whether or not they fit, so an overrun still says how much
            // room the tile actually wanted — which is what the next attempt is sized from.
            let overflowed = counters[base + Tiles3DClipKernel.Counter.overflow] != 0
                || vertexCount > Int(entry.tile.vertexCapacity)
                || indexCount > Int(entry.tile.indexCapacity)
                || cutEdgeCount > Int(entry.tile.cutCapacity)
            if overflowed {
                entry.source.growth *= 2
                handler(entry.jobIndex, .unresolved)
                continue
            }

            guard vertexCount > 0, indexCount > 0 else {
                handler(entry.jobIndex, .empty)
                continue
            }

            var lower = SIMD3<Float>(repeating: 0)
            var upper = SIMD3<Float>(repeating: 0)
            for axis in 0..<3 {
                lower[axis] = Tiles3DClipKernel.decodeBound(
                    counters[base + Tiles3DClipKernel.Counter.bounds + axis]
                )
                upper[axis] = Tiles3DClipKernel.decodeBound(
                    counters[base + Tiles3DClipKernel.Counter.bounds + 3 + axis]
                )
            }

            var cutEdges: [Tiles3DCutEdge] = []
            if cutEdgeCount > 0 {
                cutEdges.reserveCapacity(cutEdgeCount)
                let offset = Int(entry.tile.cutBase)
                for slot in 0..<cutEdgeCount {
                    cutEdges.append(cutEdgeOut[offset + slot].resolved)
                }
            }

            handler(entry.jobIndex, .clipped(
                vertices: UnsafeBufferPointer(
                    start: vertexOut + Int(entry.tile.vertexBase), count: vertexCount
                ),
                indices: UnsafeBufferPointer(
                    start: indexOut + Int(entry.tile.indexBase), count: indexCount
                ),
                cutEdges: cutEdges,
                bounds: BoundingBox(min: lower, max: upper)
            ))
        }
    }

    // MARK: - Buffers

    /// Uploads a tile's geometry the first time the outline reaches it.
    private func source(for uri: String, geometry: Tiles3DSourceGeometry) -> Source? {
        if let existing = sources[uri] { return existing }

        // The same bake the CPU clip does per call: placement into the positions, its upper-left
        // block into the normals. Done once here, since neither changes as the outline moves.
        let normalMatrix = simd_float3x3(
            SIMD3(
                geometry.placement.columns.0.x,
                geometry.placement.columns.0.y,
                geometry.placement.columns.0.z
            ),
            SIMD3(
                geometry.placement.columns.1.x,
                geometry.placement.columns.1.y,
                geometry.placement.columns.1.z
            ),
            SIMD3(
                geometry.placement.columns.2.x,
                geometry.placement.columns.2.y,
                geometry.placement.columns.2.z
            )
        )

        var vertices: [Tiles3DVertex] = []
        var indices: [UInt32] = []
        for descriptor in geometry.descriptors {
            let positions = descriptor.positions.elements
            guard !positions.isEmpty,
                  case .triangles(let sourceIndices) = descriptor.primitives,
                  sourceIndices.count >= 3
            else { continue }

            let normals = descriptor.normals?.elements
            let uvs = descriptor.textureCoordinates?.elements
            let base = UInt32(vertices.count)
            vertices.reserveCapacity(vertices.count + positions.count)
            for index in positions.indices {
                let local = positions[index]
                let world = geometry.placement * SIMD4(local.x, local.y, local.z, 1)
                let normal = normals.map { simd_normalize(normalMatrix * $0[index]) } ?? SIMD3(0, 1, 0)
                vertices.append(Tiles3DVertex(
                    position: SIMD3(world.x, world.y, world.z),
                    normal: normal,
                    uv: uvs?[index] ?? .zero
                ))
            }
            // Trailing indices that do not complete a triangle would give a thread a partial
            // primitive to read.
            let triangles = sourceIndices.count / 3
            indices.append(contentsOf: sourceIndices.prefix(triangles * 3).map { $0 + base })
        }

        guard !vertices.isEmpty, indices.count >= 3 else { return nil }
        guard let vertexRange = vertexArena.write(vertices) else { return nil }
        guard let indexRange = indexArena.write(indices) else {
            vertexArena.release(vertexRange)
            return nil
        }

        let source = Source(
            vertices: vertexRange, indices: indexRange, triangleCount: indices.count / 3
        )
        sources[uri] = source
        return source
    }

    /// Rebuilds the outline's buffers. Called once per pan step, not once per tile.
    private func uploadPrism(_ prism: BoundaryPrism) -> Bool {
        let description = prism.kernelDescription
        prismUniforms = description.uniforms

        guard let boundary = device.makeBuffer(
            bytes: description.boundary,
            length: description.boundary.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        ), let pieces = device.makeBuffer(
            bytes: description.pieces,
            length: description.pieces.count * MemoryLayout<Tiles3DClipKernel.Piece>.stride,
            options: .storageModeShared
        ), let pieceEdges = device.makeBuffer(
            bytes: description.pieceEdges,
            length: description.pieceEdges.count * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        ), let grid = device.makeBuffer(
            bytes: description.grid,
            length: description.grid.count,
            options: .storageModeShared
        ) else { return false }

        boundaryBuffer = boundary
        piecesBuffer = pieces
        pieceEdgesBuffer = pieceEdges
        gridBuffer = grid
        return true
    }

    /// Refills a per-step buffer, reusing the allocation whenever it is already large enough.
    ///
    /// The tile table and the group-to-tile map are rebuilt every step because the rim is, but their
    /// sizes settle after a step or two, so this stops allocating almost immediately.
    private func upload<T>(_ values: [T], into slot: inout (any MTLBuffer)?) -> Bool {
        let length = values.count * MemoryLayout<T>.stride
        guard length > 0 else { return false }
        if slot == nil || slot!.length < length {
            slot = device.makeBuffer(length: length, options: .storageModeShared)
        }
        guard let buffer = slot else { return false }
        values.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            buffer.contents().copyMemory(from: base, byteCount: source.count)
        }
        return true
    }

    /// Grows the shared output scratch to hold a batch, keeping whatever is already big enough.
    private func ensureScratch(vertices: Int, indices: Int, cutEdges: Int, tiles: Int) -> Bool {
        func grow(
            _ buffer: inout (any MTLBuffer)?, to length: Int
        ) -> Bool {
            guard length > 0 else { return true }
            if let buffer, buffer.length >= length { return true }
            guard let made = device.makeBuffer(length: length, options: .storageModeShared) else {
                return false
            }
            buffer = made
            return true
        }

        return grow(&vertexScratch, to: vertices * MemoryLayout<Tiles3DVertex>.stride)
            && grow(&indexScratch, to: indices * MemoryLayout<UInt32>.stride)
            && grow(&cutEdgeScratch, to: cutEdges * MemoryLayout<Tiles3DClipKernel.CutEdge>.stride)
            && grow(
                &counterScratch,
                to: tiles * Tiles3DClipKernel.countersPerTile * MemoryLayout<UInt32>.stride
            )
    }
}

/// A growable device buffer that every resident tile's source geometry is sub-allocated out of.
///
/// One dispatch reads from one source buffer, so a tile cannot keep its own — and re-uploading the
/// rim each step would give back more than the single dispatch wins, since a tile's geometry in
/// diorama space never changes when the outline moves. So tiles are allocated a range of a shared
/// arena and keep it until they are evicted, at which point the range goes on a free list for the
/// next tile to take.
///
/// Growing copies rather than re-uploading: the new buffer starts with the old one's contents at
/// offset zero, so every range already handed out stays exactly where it was.
@MainActor
private final class Arena {
    private let device: any MTLDevice
    private let stride: Int
    private(set) var buffer: (any MTLBuffer)?
    /// Elements the buffer can hold.
    private var capacity = 0
    /// Elements handed out from the front, whether or not they are still in use.
    private var end = 0
    /// Ranges given back, kept sorted and merged with their neighbours.
    private var free: [Range<Int>] = []

    /// Elements to start at, so early tiles do not each trigger a copy.
    private static let initialCapacity = 1 << 16

    init(device: any MTLDevice, stride: Int) {
        self.device = device
        self.stride = stride
    }

    /// Copies values into the arena and reports the range they landed in.
    func write<T>(_ values: [T]) -> Range<Int>? {
        guard let range = allocate(values.count), let buffer else { return nil }
        values.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            buffer.contents()
                .advanced(by: range.lowerBound * stride)
                .copyMemory(from: base, byteCount: source.count)
        }
        return range
    }

    func release(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        let slot = free.firstIndex { $0.lowerBound > range.lowerBound } ?? free.endIndex
        free.insert(range, at: slot)
        // Merging matters because tiles are evicted and reloaded continuously as the camera moves.
        // Without it the arena would fragment into slivers none of which fits a tile, and the front
        // would slide forward forever.
        if slot + 1 < free.count, free[slot].upperBound == free[slot + 1].lowerBound {
            free[slot] = free[slot].lowerBound..<free[slot + 1].upperBound
            free.remove(at: slot + 1)
        }
        if slot > 0, free[slot - 1].upperBound == free[slot].lowerBound {
            free[slot - 1] = free[slot - 1].lowerBound..<free[slot].upperBound
            free.remove(at: slot)
        }
    }

    private func allocate(_ count: Int) -> Range<Int>? {
        guard count > 0 else { return nil }
        if let slot = free.firstIndex(where: { $0.count >= count }) {
            let start = free[slot].lowerBound
            if free[slot].count == count {
                free.remove(at: slot)
            } else {
                free[slot] = (start + count)..<free[slot].upperBound
            }
            return start..<(start + count)
        }
        guard reserve(end + count) else { return nil }
        let start = end
        end += count
        return start..<(start + count)
    }

    private func reserve(_ needed: Int) -> Bool {
        guard needed > capacity else { return true }
        let grown = max(needed, capacity * 2, Self.initialCapacity)
        guard let made = device.makeBuffer(
            length: grown * stride, options: .storageModeShared
        ) else { return false }
        if let buffer, end > 0 {
            made.contents().copyMemory(from: buffer.contents(), byteCount: end * stride)
        }
        buffer = made
        capacity = grown
        return true
    }
}
