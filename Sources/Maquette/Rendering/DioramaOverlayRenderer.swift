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
        let resource = OverlayMeshResource()
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
    @ObservationIgnored private(set) var reconciliationDuration = Duration.zero
    @ObservationIgnored private(set) var materialUpdateCount = 0
    private var textures: [DioramaImageResource.Key: TextureResource] = [:]
    private var context: Context?
    private var surfaceTask: Task<OverlaySurfaceMesh?, Error>?
    // The raster's X/Z topology survives pan, zoom and height-field replacement. Its base
    // preparation is independent of cancelled per-frame height/geometry workers.
    private var rasterBaseTask: Task<OverlaySurfaceMesh, Error>?
    private var geometryJobs: [(key: Key, task: Task<[DioramaOverlayLayer], Error>)] = []
    private(set) var geometryTaskCount = 0
    var activeGeometryJobCount: Int { geometryJobs.count }
    private let sortGroup = ModelSortGroup(depthPass: .postPass)
    private static let logger = Logger(maquette: "DioramaOverlayRenderer")
    var spatialHitTesting = false
    var currentProxy: DioramaProxy?

    init(root: DioramaEntity) { self.root = root }
    func clear() {
        for record in records.values {
            record.task?.cancel(); record.collisionTask?.cancel(); record.entity.removeFromParent()
        }
        records.removeAll(); diagnostics.removeAll(); textures.removeAll()
        surfaceTask?.cancel(); surfaceTask = nil; context = nil
        rasterBaseTask?.cancel(); rasterBaseTask = nil
        for job in geometryJobs { job.task.cancel() }
        geometryJobs.removeAll()
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
            record.key = key; record.entity.isEnabled = false
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
                    return try DioramaOverlayGeometryBuilder.build(shape: shape, style: style, proxy: proxy,
                                                                   surface: surface, physicalSize: physicalSize)
                }
                geometryJobs.append((key, worker))
                geometryTaskCount += 1
            }
            record.task = Task { [weak self, weak record] in
                do {
                    // Cancellation belongs to the active-key job cache: removing one of several
                    // identical footprints must not cancel geometry still needed by another.
                    let layers = try await worker.value
                    guard !Task.isCancelled, let self, let record, self.records[input.id] === record, record.key == key else { return }
                    let completionStart = ContinuousClock.now
                    defer { self.reconciliationDuration += completionStart.duration(to: .now) }
                    let kinds = Set(layers.map(\.kind))
                    for (kind, part) in record.layers where !kinds.contains(kind) { part.model.removeFromParent(); record.layers[kind] = nil }
                    for layer in layers {
                        let part = record.layers[layer.kind] ?? Part()
                        try part.resource.update(layer.mesh)
                        part.mesh = layer.mesh
                        record.layers[layer.kind] = part
                        if part.model.parent == nil { record.entity.addChild(part.model) }
                    }
                    record.appliedKey = key
                    self.geometryBuildCount += 1; self.diagnostics[input.id] = nil
                    try self.updateMaterials(record)
                    self.updateSelection(record)
                    record.task = nil
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError), let self, let record,
                          self.records[input.id] === record, record.key == key else { return }
                    record.entity.isEnabled = false
                    let diagnostic = error as? OverlayGeometryError ?? .invalidSurface
                    self.diagnostics[input.id] = diagnostic
                    Self.logger.warning("Overlay \(input.id, privacy: .public) omitted: \(String(describing: diagnostic), privacy: .public)")
                    record.task = nil
                }
            }
        }
        updateSelection()
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
        record.entity.isEnabled = record.key == record.appliedKey && !record.layers.isEmpty && style.opacity > 0
    }

    func updateSelection() {
        for record in records.values { updateSelection(record) }
    }
    private func updateSelection(_ record: Record) {
        // Completion changes one record; refreshing every sibling made N completions O(N²).
        let identity = DioramaMarkerIdentity(annotationID: record.input.annotation.selectionAnnotationID ?? record.input.annotation.id,
            tag: record.input.annotation.selectionTag, allowsLegacyID: false)
        record.entity.components.set(identity)
        record.entity.components.set(DioramaOverlaySelectionState(isSelected: root?.selection?.isSelected(identity) ?? false))
        configureSpatialTarget(record, identity: identity)
    }
    func waitUntilIdle() async {
        for task in records.values.compactMap(\.task) { await task.value }
        for task in records.values.compactMap(\.collisionTask) { await task.value }
    }
    func surfaceForCollision() async throws -> OverlaySurfaceMesh? { try await surfaceTask?.value }
}

struct DioramaOverlaySelectionState: Component { var isSelected: Bool }
