import Foundation
import os
import RealityKit
import Observation
import SwiftUI

/// Owns only current content. Geometry keys exclude materials, image revision, and selection.
@MainActor
@Observable final class DioramaOverlayRenderer {
    struct Context: Equatable {
        var terrain: ObjectIdentifier?
        var revision: Int
        var surfaceID: UUID?
        var anchor: TerrainAnchor?
        var center: Coordinate
        var pan: SIMD2<Float>
        var boundary: [SIMD2<Float>]
        var datum: Float
        var scale: Float
        var physicalSize: Float
    }
    struct Key: Equatable {
        var context: Context
        var shape: DioramaOverlayShape
        var altitude: AltitudeReference
        var stroke: DioramaStrokeStyle?
    }
    @MainActor final class Part {
        let model = ModelEntity()
        var resource = OverlayMeshResource()
        var mesh = OverlayMesh()
        var installedResource: MeshResource?
        var installedStyle: DioramaFeatureStyle?
        var installedImage: DioramaImageResource.Key?
        var installedOrder: Int?
    }
    @MainActor final class Record {
        let entity = ModelEntity()
        var input: DioramaOverlayInput
        var key: Key?
        var appliedKey: Key?
        var order = 0
        var layers: [DioramaOverlayLayerKind: Part] = [:]
        var task: Task<Void, Never>?
        var collisionTask: Task<Void, Never>?
        var collisionKey: Key?
        var collisionRequest = UUID()
        init(_ input: DioramaOverlayInput) { self.input = input; entity.name = "Overlay_\(input.id)" }
    }
    weak var root: DioramaEntity?
    private(set) var records: [String: Record] = [:]
    private(set) var diagnostics: [String: OverlayGeometryError] = [:]
    private(set) var geometryBuildCount = 0
    private(set) var textureUploadCount = 0
    private(set) var meshUploadCount = 0
    private var imageMeshes: [(key: Key, resource: OverlayMeshResource)] = []
    @ObservationIgnored private(set) var reconciliationDuration = Duration.zero
    @ObservationIgnored private(set) var materialUpdateCount = 0
    @ObservationIgnored private(set) var selectionComponentUpdateCount = 0
    private var textures: [DioramaImageResource.Key: TextureResource] = [:]
    private var context: Context?
    private var surfaceTask: Task<OverlaySurfaceMesh?, Error>?
    // The raster's X/Z topology survives pan, zoom and height-field replacement. Its base
    // preparation is independent of cancelled per-frame height/geometry workers.
    private var rasterBaseTask: Task<OverlaySurfaceMesh, Error>?
    private var geometryJobs: [(key: Key, task: Task<[DioramaOverlayLayer], Error>)] = []
    private(set) var geometryTaskCount = 0
    var activeGeometryJobCount: Int { geometryJobs.count }
    // Hold one complete terrain/overlay frame while detached workers prepare its replacement.
    private(set) var panPresentationCount = 0
    #if MAQUETTE_PROFILING
    private nonisolated static let profileSignposter = OSSignposter(logger: Logger(maquette: "PointsOfInterest"))
    private var loggedPanInvalidations = 0
    private var profileReconciliationPriorities: Set<UInt8> = []
    private var profileFrameStart = ContinuousClock.now
    private(set) var profileFrameDurations: [Double] = []
    #endif
    private var panKeys: [String: Key]?
    private var panResults: [String: Result<[DioramaOverlayLayer], OverlayGeometryError>] = [:]
    var canDeferPanPresentation: Bool {
        records.values.contains { $0.entity.isEnabled && $0.appliedKey != nil }
    }
    private let sortGroup = ModelSortGroup(depthPass: .postPass)
    private static let logger = Logger(maquette: "DioramaOverlayRenderer")
    var spatialHitTesting = false
    var currentProxy: DioramaProxy?

    init(root: DioramaEntity) { self.root = root }
    func clear() {
        for record in records.values {
            record.task?.cancel(); record.collisionTask?.cancel(); record.entity.removeFromParent()
        }
        records.removeAll(); diagnostics.removeAll(); textures.removeAll(); imageMeshes.removeAll()
        surfaceTask?.cancel(); surfaceTask = nil; context = nil
        rasterBaseTask?.cancel(); rasterBaseTask = nil
        for job in geometryJobs { job.task.cancel() }
        geometryJobs.removeAll()
        panKeys = nil; panResults.removeAll()
        root?.finishPanPresentation(applyPlacement: false)?(false)
    }
    func apply(_ inputs: [DioramaOverlayInput], proxy: DioramaProxy, physicalSize: Float) {
        guard let root else { return }
        currentProxy = proxy
        guard !inputs.isEmpty else { clear(); return }
        let current = Context(terrain: root.terrain.map(ObjectIdentifier.init), revision: root.terrain?.surfaceRevision ?? root.tiles3D?.surfaceRevision ?? 0,
            surfaceID: (proxy.projection as? EllipsoidProjection)?.surface?.id,
            anchor: (proxy.projection as? TerrainProjection)?.anchor, center: Coordinate(proxy.configuration.center),
            pan: proxy.projection.panOffset, boundary: proxy.configuration.boundary.vertices,
            datum: proxy.projection.y(forElevation: 0), scale: proxy.projection.y(forElevation: 1), physicalSize: physicalSize)
        var previous = context
        previous?.pan = current.pan; previous?.revision = current.revision
        previous?.anchor = current.anchor; previous?.datum = current.datum; previous?.scale = current.scale
        let wasDeferred = root.terrain?.isPanPresentationDeferred == true
        let coherentPan = wasDeferred && previous == current
        var supersededCompletion: ((Bool) -> Void)?
        if !coherentPan {
            panKeys = nil; panResults.removeAll()
            supersededCompletion = root.finishPanPresentation(applyPlacement: false)
        }
        if current != context || surfaceTask == nil {
            let sameTerrain = current.terrain != nil && current.terrain == context?.terrain
            surfaceTask?.cancel(); context = current
            let buffers = root.terrain?.surfaceBuffers
            let photorealistic = (proxy.projection as? EllipsoidProjection)?.surface
            if let buffers {
                let needsBase = !sameTerrain || rasterBaseTask == nil
                if needsBase {
                    rasterBaseTask?.cancel()
                    rasterBaseTask = Task.detached(priority: .userInitiated) { try OverlaySurfaceMesh(terrain: buffers) }
                }
                let base = rasterBaseTask!
                surfaceTask = Task.detached(priority: .userInitiated) {
                    let previous = try await base.value
                    try Task.checkCancellation()
                    if needsBase { return previous }
                    #if MAQUETTE_PROFILING
                    let interval = Self.profileSignposter.beginInterval("SurfaceRefit", id: Self.profileSignposter.makeSignpostID())
                    defer { Self.profileSignposter.endInterval("SurfaceRefit", interval) }
                    #endif
                    return try OverlaySurfaceMesh(terrain: buffers, reusing: previous)
                }
            } else {
                rasterBaseTask?.cancel(); rasterBaseTask = nil
                surfaceTask = Task.detached(priority: .userInitiated) { photorealistic }
            }
        }
        let keys = inputs.map { input in
            Key(context: current, shape: input.shape, altitude: input.annotation.style.altitude,
                stroke: input.shape.isLine || input.annotation.style.stroke != nil ? input.annotation.style.strokeStyle : nil)
        }
        if coherentPan {
            #if MAQUETTE_PROFILING
            profileFrameStart = .now
            #endif
            var requested: [String: Key] = [:]
            for (input, key) in zip(inputs, keys) { requested[input.id] = key }
            if panKeys != requested {
                let previousKeys = panKeys
                panResults = panResults.filter { requested[$0.key] == previousKeys?[$0.key] }
                panKeys = requested
            }
        }
        imageMeshes.removeAll { entry in !keys.contains(entry.key) }
        geometryJobs.removeAll { job in
            guard !keys.contains(job.key) else { return false }
            job.task.cancel(); return true
        }
        let active = Set(inputs.map(\.id))
        for (id, record) in records where !active.contains(id) {
            record.task?.cancel(); record.collisionTask?.cancel(); record.entity.removeFromParent(); records[id] = nil; diagnostics[id] = nil
        }
        let imageKeys = Set(inputs.compactMap { input -> DioramaImageResource.Key? in
            if case .image(let image, _) = input.annotation.overlay { return image.key }; return nil
        })
        textures = textures.filter { imageKeys.contains($0.key) }
        for (order, input) in inputs.enumerated() {
            let record = records[input.id] ?? Record(input)
            if records[input.id] == nil { records[input.id] = record; root.addChild(record.entity) }
            record.input = input; record.order = order
            let key = keys[order]
            if record.key == key {
                do {
                    try updateMaterials(record)
                    if record.appliedKey == key { diagnostics[input.id] = nil }
                } catch {
                    record.entity.isEnabled = false
                    diagnostics[input.id] = error as? OverlayGeometryError ?? .invalidSurface
                }
                continue
            }
            record.task?.cancel(); record.collisionTask?.cancel(); record.collisionTask = nil
            record.collisionRequest = UUID(); record.collisionKey = nil
            let keepsPresentedMesh = coherentPan && record.appliedKey.map {
                $0.shape == key.shape && $0.altitude == key.altitude && $0.stroke == key.stroke
            } == true
            record.key = key
            if !keepsPresentedMesh {
                #if MAQUETTE_PROFILING
                if record.entity.isEnabled, let applied = record.appliedKey, loggedPanInvalidations < 4 {
                    loggedPanInvalidations += 1
                    let changes = [("terrain", applied.context.terrain != current.terrain),
                        ("anchor", applied.context.anchor != current.anchor),
                        ("center", applied.context.center != current.center),
                        ("boundary", applied.context.boundary != current.boundary),
                        ("datum", applied.context.datum != current.datum),
                        ("scale", applied.context.scale != current.scale),
                        ("shape", applied.shape != key.shape),
                        ("style", applied.altitude != key.altitude || applied.stroke != key.stroke),
                        ("size", applied.context.physicalSize != current.physicalSize),
                        ("surfaceID", applied.context.surfaceID != current.surfaceID)]
                        .filter { $0.1 }.map { $0.0 }.joined(separator: ",")
                    Self.logger.notice("PROFILE invalidation coherentPan=\(coherentPan) wasDeferred=\(wasDeferred) previousMatches=\(previous == current) terrainPanMatches=\(root.terrain?.panOffset == current.pan) fields=\(changes, privacy: .public)")
                }
                #endif
                record.entity.isEnabled = false
            }
            record.entity.components.remove(CollisionComponent.self)
            let shape = input.shape, prepared = surfaceTask!
            // Opacity belongs to each record's material, never its shared geometry job.
            // A malformed sibling must not poison an otherwise valid footprint.
            var geometryStyle = input.annotation.style
            geometryStyle.opacity = 1
            let style = geometryStyle
            let worker: Task<[DioramaOverlayLayer], Error>
            if let shared = geometryJobs.first(where: { $0.key == key }) {
                worker = shared.task
            } else {
                worker = Task.detached(priority: .userInitiated) {
                    let surface = try await prepared.value
                    try Task.checkCancellation()
                    #if MAQUETTE_PROFILING
                    let interval = Self.profileSignposter.beginInterval("OverlayGeometry", id: Self.profileSignposter.makeSignpostID())
                    defer { Self.profileSignposter.endInterval("OverlayGeometry", interval) }
                    #endif
                    return try DioramaOverlayGeometryBuilder.build(shape: shape, style: style, proxy: proxy,
                                                                   surface: surface, physicalSize: physicalSize)
                }
                geometryJobs.append((key, worker))
                geometryTaskCount += 1
            }
            record.task = Task { [weak self, weak record] in
                #if MAQUETTE_PROFILING
                let priority = Task.currentPriority.rawValue
                if let self, self.profileReconciliationPriorities.insert(priority).inserted {
                    Self.logger.notice("PROFILE reconciliationPriority=\(priority)")
                }
                #endif
                do {
                    // Cancellation belongs to the active-key job cache: removing one of several
                    // identical footprints must not cancel geometry still needed by another.
                    let layers = try await worker.value
                    guard !Task.isCancelled, let self, let record, self.records[input.id] === record, record.key == key else { return }
                    let completionStart = ContinuousClock.now
                    defer { self.reconciliationDuration += completionStart.duration(to: .now) }
                    if self.panKeys?[input.id] == key {
                        self.panResults[input.id] = .success(layers)
                        record.task = nil
                        self.finishPanIfReady()
                    } else {
                        try self.install(layers, on: record, key: key)
                    }
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError), let self, let record,
                          self.records[input.id] === record, record.key == key else { return }
                    let diagnostic = error as? OverlayGeometryError ?? .invalidSurface
                    if self.panKeys?[input.id] == key {
                        self.panResults[input.id] = .failure(diagnostic)
                        record.task = nil
                        self.finishPanIfReady()
                    } else { self.omit(record, diagnostic: diagnostic) }
                }
            }
        }
        updateSelection()
        finishPanIfReady()
        supersededCompletion?(true)
    }

    private func finishPanIfReady() {
        guard let keys = panKeys, keys.count == panResults.count else { return }
        let results = panResults
        panKeys = nil; panResults.removeAll()
        // No suspension between the terrain buffer write and every matching overlay install.
        for (id, key) in keys {
            guard let record = records[id], record.key == key, let result = results[id] else { continue }
            do { try install(result.get(), on: record, key: key) }
            catch { omit(record, diagnostic: error as? OverlayGeometryError ?? .invalidSurface) }
        }
        #if MAQUETTE_PROFILING
        profileFrameDurations.append(profileFrameStart.duration(to: .now).milliseconds)
        #endif
        panPresentationCount += 1
        #if MAQUETTE_PROFILING
        let publish = Self.profileSignposter.beginInterval("TerrainPublish", id: Self.profileSignposter.makeSignpostID())
        let completion = root?.finishPanPresentation()
        Self.profileSignposter.endInterval("TerrainPublish", publish)
        completion?(true)
        #else
        root?.finishPanPresentation()?(true)
        #endif
    }

    private func install(_ layers: [DioramaOverlayLayer], on record: Record, key: Key) throws {
        #if MAQUETTE_PROFILING
        let interval = Self.profileSignposter.beginInterval("OverlayInstall", id: Self.profileSignposter.makeSignpostID())
        defer { Self.profileSignposter.endInterval("OverlayInstall", interval) }
        #endif
        let kinds = Set(layers.map(\.kind))
        for (kind, part) in record.layers where !kinds.contains(kind) { part.model.removeFromParent(); record.layers[kind] = nil }
        for layer in layers {
            let part = record.layers[layer.kind] ?? Part()
            if layer.kind == .image {
                if let shared = imageMeshes.first(where: { $0.key == key }) {
                    part.resource = shared.resource
                } else {
                    // A shared displayed mesh may be refilled only if every remaining owner
                    // wants this exact candidate. A footprint edit detaches before writing.
                    let hasOtherMapping = records.values.contains { sibling in
                        sibling.key != key && sibling.layers[.image]?.resource === part.resource
                    }
                    if hasOtherMapping { part.resource = OverlayMeshResource() }
                    try part.resource.update(layer.mesh)
                    meshUploadCount += 1
                    imageMeshes.append((key, part.resource))
                }
            } else {
                // Filled areas grow quadratically during ground zoom. Reserve modest headroom
                // at allocation so the first pinch does not rebuild many resources together.
                try part.resource.update(layer.mesh, reserveForGrowth: layer.kind == .fill)
                meshUploadCount += 1
            }
            part.mesh = layer.mesh
            record.layers[layer.kind] = part
            if part.model.parent == nil { record.entity.addChild(part.model) }
        }
        record.appliedKey = key
        geometryBuildCount += 1; diagnostics[record.input.id] = nil
        try updateMaterials(record)
        updateSelection(record)
        record.task = nil
    }

    private func omit(_ record: Record, diagnostic: OverlayGeometryError) {
        record.entity.isEnabled = false
        diagnostics[record.input.id] = diagnostic
        Self.logger.warning("Overlay \(record.input.id, privacy: .public) omitted: \(String(describing: diagnostic), privacy: .public)")
        record.task = nil
    }

    private func updateMaterials(_ record: Record) throws {
        let style = record.input.annotation.style
        guard style.opacity.isFinite else { throw OverlayGeometryError.nonFiniteInput }
        for (kind, part) in record.layers {
            let imageKey: DioramaImageResource.Key?
            if kind == .image, case .image(let image, _) = record.input.annotation.overlay { imageKey = image.key }
            else { imageKey = nil }
            // Buffer writes already update a retained LowLevelMesh. Reinstall a component only
            // when its resource, appearance, image revision or draw order actually changes.
            if part.installedResource === part.resource.resource, part.installedStyle == style,
               part.installedImage == imageKey, part.installedOrder == record.order { continue }
            var material = DioramaMaterials.unlitMaterial(color: kind == .fill ? style.fill : style.stroke ?? style.tint)
            if kind == .image, case .image(let image, _) = record.input.annotation.overlay {
                let texture: TextureResource
                if let cached = textures[image.key] { texture = cached }
                else {
                    texture = try TextureResource(image: image.image, options: .init(semantic: .color))
                    textures[image.key] = texture; textureUploadCount += 1
                }
                material = DioramaMaterials.unlitMaterial(color: .white)
                material.color.texture = .init(texture)
            }
            material.blending = .transparent(opacity: .init(floatLiteral: Float(max(0, min(1, style.opacity)))))
            material.readsDepth = true; material.writesDepth = false
            if let resource = part.resource.resource { part.model.model = ModelComponent(mesh: resource, materials: [material]) }
            let offset = kind == .stroke ? 1 : 0
            part.model.components.set(ModelSortGroupComponent(group: sortGroup, order: Int32(clamping: record.order * 2 + offset)))
            part.installedResource = part.resource.resource; part.installedStyle = style
            part.installedImage = imageKey; part.installedOrder = record.order
            materialUpdateCount += 1
        }
        let presented = panKeys?[record.input.id] == record.key && record.appliedKey.map {
            $0.shape == record.key?.shape && $0.altitude == record.key?.altitude && $0.stroke == record.key?.stroke
        } == true
        record.entity.isEnabled = (record.key == record.appliedKey || presented) && !record.layers.isEmpty && style.opacity > 0
    }

    func updateSelection() {
        for record in records.values { updateSelection(record) }
    }
    private func updateSelection(_ record: Record) {
        // Completion changes one record; refreshing every sibling made N completions O(N²).
        let identity = DioramaMarkerIdentity(annotationID: record.input.annotation.selectionAnnotationID ?? record.input.annotation.id,
            tag: record.input.annotation.selectionTag, allowsLegacyID: false)
        // Entity component setters dirty RealityKit state even when their values are unchanged.
        // Ground movement changes mesh buffers, not selection identity or selected appearance.
        if record.entity.components[DioramaMarkerIdentity.self] != identity {
            record.entity.components.set(identity)
            selectionComponentUpdateCount += 1
        }
        let selected = root?.selection?.isSelected(identity) ?? false
        if record.entity.components[DioramaOverlaySelectionState.self]?.isSelected != selected {
            record.entity.components.set(DioramaOverlaySelectionState(isSelected: selected))
            selectionComponentUpdateCount += 1
        }
        configureSpatialTarget(record, identity: identity)
    }
    func waitUntilIdle() async {
        while true {
            let tasks = records.values.flatMap { [$0.task, $0.collisionTask].compactMap { $0 } }
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }
    func surfaceForCollision() async throws -> OverlaySurfaceMesh? { try await surfaceTask?.value }
}

struct DioramaOverlaySelectionState: Component { var isSelected: Bool }
