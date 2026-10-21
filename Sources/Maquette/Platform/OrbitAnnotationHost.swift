#if os(iOS) || os(macOS)
import RealityKit
import SwiftUI
#if canImport(_RealityKit_SwiftUI)
@preconcurrency import _RealityKit_SwiftUI
#endif

/// Context is installed by RealityView; observed layout is published after its update transaction.
@MainActor @Observable
final class OrbitAnnotationCoordinator {
    @ObservationIgnored private var context: RealityViewCameraContent?
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var indices: [DioramaAnnotationOcclusionIndex] = []
    @ObservationIgnored private weak var indexedTerrain: TerrainEntity?
    @ObservationIgnored private weak var requestedTerrain: TerrainEntity?
    @ObservationIgnored private var indexTask: Task<Void, Never>?

    func install(_ context: RealityViewCameraContent, model: OrbitDioramaModel) {
        self.context = context
        requestLayout(model)
    }

    func requestLayout(_ model: OrbitDioramaModel) {
        guard !pending else { return }
        pending = true
        Task { @MainActor [weak self, weak model] in
            guard let self else { return }
            self.pending = false
            guard let model else { return }
            self.layout(model)
        }
    }

    private func updateIndex(_ terrain: TerrainEntity, model: OrbitDioramaModel) {
        // Resampling only changes heights. Each terrain entity owns immutable X/Z topology.
        guard requestedTerrain !== terrain else { return }
        requestedTerrain = terrain
        indexTask?.cancel()
        let buffers = [terrain.surfaceBuffers, terrain.wallBuffers, terrain.bottomBuffers].compactMap { $0 }
        let build = Task.detached(priority: .userInitiated) {
            buffers.map { DioramaAnnotationOcclusionIndex(positions: $0.positions, indices: $0.indices, dynamicHeights: true) }
        }
        indexTask = Task { [weak self, weak model] in
            let result = await withTaskCancellationHandler { await build.value } onCancel: { build.cancel() }
            guard !Task.isCancelled, let self, let model, self.requestedTerrain === terrain else { return }
            self.indices = result
            self.indexedTerrain = terrain
            self.requestLayout(model)
        }
    }

    private func layout(_ model: OrbitDioramaModel) {
        let records = Array(model.store.annotationRegistry.orderedRecords.prefix(DioramaAnnotationLayout.hostedLimit))
        guard !records.isEmpty else { return }
        guard let context, let root = model.store.dioramaEntity as? DioramaEntity,
              root.isEnabled, !model.transition.isBusy, !model.transition.isShowingGlobe,
              let projection = model.store.projection, model.viewSize.width > 0, model.viewSize.height > 0 else {
            for record in records where record.visible { record.visible = false }
            return
        }
        if let terrain = root.terrain { updateIndex(terrain, model: model) }
        let viewport = CGRect(origin: .zero, size: model.viewSize)
        var candidates: [DioramaAnnotationLayout.Candidate] = []
        for record in records {
            guard record.feature.style.opacity > 0, let descriptor = record.descriptor,
                  let local = DioramaAnnotationPlacement.position(for: record.feature, projection: projection, configuration: model.store.configuration) else { continue }
            let scenePoint = root.convert(position: local, to: nil)
            guard let screenPoint = context.project(point: scenePoint, to: .local),
                  screenPoint.x.isFinite, screenPoint.y.isFinite, viewport.contains(screenPoint),
                  let ray = context.ray(through: screenPoint, in: .local, to: .scene),
                  simd_dot(scenePoint - ray.origin, ray.direction) > 0 else { continue }
            if descriptor.occlusion == .terrain {
                guard let terrain = root.terrain, indexedTerrain === terrain else { continue }
                let buffers = [terrain.surfaceBuffers, terrain.wallBuffers, terrain.bottomBuffers].compactMap { $0 }
                guard indices.count == buffers.count else { continue }
                let origin = root.convert(position: ray.origin, from: nil)
                let tolerance = model.store.configuration.physicalSize * 0.0002
                if zip(indices, buffers).contains(where: { $0.0.occludes(from: origin, to: local, positions: $0.1.positions, tolerance: tolerance) }) { continue }
            }
            let frame = DioramaAnnotationLayout.frame(at: screenPoint, size: record.measuredSize,
                anchorX: descriptor.anchor.x, anchorY: descriptor.anchor.y, offset: descriptor.offset)
            if record.frame != frame { record.frame = frame }
            candidates.append(.init(id: record.id, frame: frame, priority: descriptor.priority,
                depth: simd_distance(scenePoint, ray.origin), allowsOverlap: descriptor.overlap == .allow))
        }
        let visible = Set(DioramaAnnotationLayout.visible(candidates))
        for record in records {
            let show = visible.contains(record.id) && record.feature.style.opacity > 0
            if record.visible != show { record.visible = show }
        }
    }
}

struct OrbitAnnotationHost: View {
    let model: OrbitDioramaModel
    let coordinator: OrbitAnnotationCoordinator

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.store.annotationRegistry.orderedRecords.prefix(DioramaAnnotationLayout.hostedLimit)), id: \.lifetimeID) { record in
                DioramaAnnotationLabel(record: record, selection: model.selectionBinding, didSelect: { model.applySelection() })
                    .modifier(OrbitAnnotationNavigation(model: model))
                    .opacity(record.visible ? max(0, min(1, record.feature.style.opacity)) : 0)
                    .allowsHitTesting(record.visible)
                    .accessibilityHidden(!record.visible)
                    .position(x: record.frame?.midX ?? 0, y: record.frame?.midY ?? 0)
                    .onChange(of: record.measuredSize) { _, _ in coordinator.requestLayout(model) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onAppear { coordinator.requestLayout(model) }
        .onChange(of: model.store.annotationPlacementRevision) { _, _ in coordinator.requestLayout(model) }
        .onChange(of: model.viewSize) { _, _ in coordinator.requestLayout(model) }
    }
}
/// Ordinary ancestor gestures yield to control-owned gestures; they do not run simultaneously
/// with text selection or sliders. A drag on decorative content remains scene navigation.
private struct OrbitAnnotationNavigation: ViewModifier {
    let model: OrbitDioramaModel
    @State private var lastDrag = CGSize.zero

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .highPriorityGesture(DragGesture(minimumDistance: 8).modifiers(.option)
                .onChanged { value in drag(value.translation, orbit: true) }
                .onEnded { _ in end() })
            #endif
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { value in drag(value.translation, orbit: false) }
                .onEnded { _ in end() })
    }

    private func drag(_ translation: CGSize, orbit: Bool) {
        let dx = Float(translation.width - lastDrag.width)
        let dy = Float(translation.height - lastDrag.height)
        lastDrag = translation
        if orbit { model.secondaryDrag(dx: dx, dy: dy) }
        else { model.primaryDrag(dx: dx, dy: dy) }
    }
    private func end() { lastDrag = .zero; model.endInteraction(.drag) }
}
#endif
