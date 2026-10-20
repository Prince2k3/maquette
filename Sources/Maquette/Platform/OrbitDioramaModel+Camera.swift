#if os(iOS) || os(macOS)
import Foundation
import RealityKit
import SwiftUI
import simd

struct OrbitCameraMotion {
    var from: DioramaCameraPose
    var to: DioramaCameraPose
    var focus: DioramaCameraFocus
    var started: Date
    var duration: TimeInterval
    var request: DioramaCameraRequestID?
    var revision: Int
}

extension OrbitDioramaModel {
    var cameraPose: DioramaCameraPose {
        .init(heading: resolvedCamera.heading.degrees, pitch: resolvedCamera.pitch.degrees,
              distance: cameraController.distance, target: cameraController.target)
    }

    func bindCameraHost(_ reader: CameraActionHost?) {
        if readerCameraHost !== reader {
            cancelCameraAction()
            readerCameraHost?.release(owner: self)
            readerCameraHost = reader?.claim(self) == true ? reader : nil
        }
        let host = cameraHost
        guard host.claim(self) else { return }
        host.receive = { [weak self] id, command in self?.receiveCameraAction(id, command) }
        host.cancel = { [weak self] id in
            guard let self else { return }
            self.stopCameraMotion(request: id)
        }
        updateCameraCapabilities()
    }

    func releaseCameraHost() {
        cancelCameraAction()
        cancelCameraRecovery()
        cameraHost.release(owner: self)
    }

    func updateCameraCapabilities() {
        let available = !arPlacementActive && (store.loadingState == .loaded || transition.isShowingGlobe)
        // Explicit requests can settle globe/follow ownership before taking the camera.
        cameraHost.capabilities = .init(canOrbit: available, canFit: available && store.dioramaEntity != nil)
    }

    func configureCamera(limits: DioramaCameraLimits, transition: DioramaCameraTransition, reduceMotion: Bool) {
        let limitsChanged = cameraLimits != limits
        cameraLimits = limits
        cameraTransition = transition.isValid ? transition : .immediate
        self.reduceMotion = reduceMotion
        cameraController.minDistance = limits.distance.lowerBound
        cameraController.maxDistance = limits.distance.upperBound
        chunkElevationLimits = Float((90 - limits.pitchDegrees.upperBound) * .pi / 180)...Float((90 - limits.pitchDegrees.lowerBound) * .pi / 180)
        if !self.transition.isShowingGlobe {
            cameraController.minElevation = chunkElevationLimits.lowerBound
            cameraController.maxElevation = chunkElevationLimits.upperBound
            if limitsChanged {
                cancelCameraAction()
                constrainCamera()
                refreshCameraFocus()
                writeCameraReadback(user: false)
            }
        }
        if reduceMotion, let motion = cameraMotion {
            applyPose(motion.to)
            cameraFocus = motion.focus
            finishCameraMotion(motion)
        }
    }

    func cameraPose(for camera: DioramaCamera, permitsPendingProjection: Bool = false) -> DioramaCameraPose? {
        guard camera.isValid else { return nil }
        let target: SIMD3<Float>
        switch camera.focus {
        case .chunkCenter: target = .init(0, chunkCenterY * entityScale, 0)
        case .coordinate(let coordinate, let altitude):
            guard let projection = store.projection else {
                return permitsPendingProjection ? .init(heading: DioramaCameraGeometry.normalizedHeading(camera.heading.degrees),
                    pitch: min(max(camera.pitch.degrees, cameraLimits.pitchDegrees.lowerBound), cameraLimits.pitchDegrees.upperBound),
                    distance: min(max(camera.distance, cameraLimits.distance.lowerBound), cameraLimits.distance.upperBound),
                    target: cameraController.target) : nil
            }
            let coordinate = cameraCoordinate(coordinate)
            let horizontal = projection.point(for: coordinate)
            guard cameraLimits.focusPolicy == .unrestricted || store.configuration.boundary.contains(horizontal),
                  let point = projection.position(for: coordinate, altitude: altitude), finite(point) else { return nil }
            target = point * entityScale
        }
        return .init(heading: DioramaCameraGeometry.normalizedHeading(camera.heading.degrees),
                     pitch: min(max(camera.pitch.degrees, cameraLimits.pitchDegrees.lowerBound), cameraLimits.pitchDegrees.upperBound),
                     distance: min(max(camera.distance, cameraLimits.distance.lowerBound), cameraLimits.distance.upperBound), target: target)
    }

    func applyPose(_ pose: DioramaCameraPose) {
        cameraController.azimuth = Float(-pose.heading * .pi / 180)
        cameraController.elevation = Float((90 - pose.pitch) * .pi / 180)
        cameraController.distance = pose.distance
        cameraController.target = pose.target
    }

    func constrainCamera() {
        guard !transition.isShowingGlobe else { return }
        cameraController.elevation = min(max(cameraController.elevation, chunkElevationLimits.lowerBound), chunkElevationLimits.upperBound)
        cameraController.distance = min(max(cameraController.distance, cameraLimits.distance.lowerBound), cameraLimits.distance.upperBound)
    }

    func writeCameraReadback(user: Bool) {
        guard !arPlacementActive else { return }
        let position = user ? DioramaCameraPosition.userPositioned(resolvedCamera) : .camera(resolvedCamera)
        lastAppliedPosition = position
        if positionBinding?.wrappedValue != position { positionBinding?.wrappedValue = position }
    }

    func refreshCameraFocus() {
        guard !transition.isShowingGlobe, !arPlacementActive, cameraController.followMode == .orbit else { return }
        if var motion = cameraMotion {
            let destination = DioramaCamera(heading: .degrees(motion.to.heading), pitch: .degrees(motion.to.pitch),
                distance: motion.to.distance, focus: motion.focus)
            if let resolved = cameraPose(for: destination) { motion.to = resolved; cameraMotion = motion }
            return
        }
        if let pose = cameraPose(for: resolvedCamera) {
            applyPose(pose)
        } else if case .coordinate = cameraFocus {
            // A pan can carry a constrained geographic focus off the cutout.
            cameraFocus = .chunkCenter
            cameraController.target = .init(0, chunkCenterY * entityScale, 0)
        }
        writeCameraReadback(user: false)
    }

    func geographicFocus(for point: SIMD3<Float>) -> DioramaCameraFocus? {
        guard let projection = store.projection else { return nil }
        let point = point / entityScale
        var coordinate: Coordinate?
        if let terrain = projection as? TerrainProjection {
            coordinate = terrain.anchor.coordinate(forDioramaX: Double(point.x + terrain.panOffset.x), z: Double(point.z + terrain.panOffset.y))
        } else if let ellipsoid = projection as? EllipsoidProjection {
            coordinate = ellipsoid.converter.coordinate(atHorizontalPoint: SIMD2<Double>(Double(point.x + ellipsoid.panOffset.x), Double(point.z + ellipsoid.panOffset.y)) / Double(ellipsoid.geographicScale))
        }
        let scale = projection.y(forElevation: 1) - projection.y(forElevation: 0)
        guard var coordinate, scale.isFinite, abs(scale) > 1e-12 else { return nil }
        coordinate.altitude = Double((point.y - projection.y(forElevation: 0)) / scale)
        return .coordinate(coordinate, altitude: .absolute)
    }

    func settleCameraOwnership() {
        if transition.isShowingGlobe || transition.isBusy {
            let relocation = handoff.relocationTask
            let needsRecovery = store.loadingState == .loading
            cancelHandoffForNavigation()
            if needsRecovery, let relocation { recoverCameraGround(after: relocation) }
        }
        cameraController.stopFollowingAtCurrentPose()
        constrainCamera()
    }

    func cancelCameraRecovery() {
        cameraRecoveryRevision += 1
        cameraRecoveryTask?.cancel()
        cameraRecoveryTask = nil
    }

    /// A camera-only command does not replace geography. Finish the interrupted load independently
    /// of the old globe continuation, which no longer owns framing or content application.
    func recoverCameraGround(after cancelledRelocation: Task<Void, Never>) {
        cancelCameraRecovery()
        let revision = cameraRecoveryRevision
        cameraRecoveryTask = Task { [weak self] in
            await cancelledRelocation.value
            guard let self, !Task.isCancelled, self.cameraRecoveryRevision == revision else { return }
            await self.store.load()
            guard !Task.isCancelled, self.cameraRecoveryRevision == revision else { return }
            self.store.applyContent(self.content)
            self.frameLoadedChunk()
            self.cameraRecoveryTask = nil
        }
    }

    func interruptCameraForGesture() {
        cancelCameraAction()
        cameraController.stopFollowingAtCurrentPose()
    }

    func cancelCameraAction() {
        let revision = cameraActionRevision
        cameraHost.cancelActive()
        // Cancellation observers may synchronously submit a newer camera action.
        if cameraActionRevision == revision { stopCameraMotion(request: nil) }
    }

    func stopCameraMotion(request: DioramaCameraRequestID?) {
        if let request, let motion = cameraMotion, motion.request != request { return }
        cameraActionRevision += 1
        cameraFitTask?.cancel(); cameraFitTask = nil
        if cameraMotion != nil {
            cameraMotion = nil
            cameraFocus = geographicFocus(for: cameraController.target) ?? cameraFocus
            cameraObservation.finishedAction(resolvedCamera, cancelled: true)
            writeCameraReadback(user: false)
        }
    }

    func moveCamera(to pose: DioramaCameraPose, focus: DioramaCameraFocus,
                    transition: DioramaCameraTransition, request: DioramaCameraRequestID?) {
        let duration: TimeInterval
        switch transition {
        case .immediate: duration = 0
        case .easeInOut(let seconds): duration = reduceMotion ? 0 : seconds
        }
        guard duration.isFinite, duration >= 0 else { return }
        usesAutomaticCamera = false
        cameraActionRevision += 1
        let revision = cameraActionRevision
        cameraObservation.beganAction()
        if duration == 0 {
            applyPose(pose); cameraFocus = focus
            writeCameraReadback(user: false)
            guard cameraActionRevision == revision else { return }
            cameraObservation.changed(resolvedCamera, origin: .programmatic, force: true)
            guard cameraActionRevision == revision else { return }
            cameraChangeAction?.action(resolvedCamera)
            guard cameraActionRevision == revision else { return }
            let final = resolvedCamera
            if let request { cameraHost.complete(request, camera: final) }
            cameraObservation.finishedAction(final)
        } else {
            cameraMotion = .init(from: cameraPose, to: pose, focus: focus, started: cameraClock(), duration: duration, request: request, revision: revision)
            cameraObservation.changed(resolvedCamera, origin: .programmatic, force: true)
        }
    }

    func advanceCameraMotion(at date: Date) {
        guard let motion = cameraMotion else { return }
        let progress = max(0, min(1, date.timeIntervalSince(motion.started) / motion.duration))
        applyPose(DioramaCameraGeometry.interpolate(from: motion.from, to: motion.to, progress: progress))
        cameraFocus = progress == 1 ? motion.focus : geographicFocus(for: cameraController.target) ?? cameraFocus
        writeCameraReadback(user: false)
        guard cameraActionRevision == motion.revision else { return }
        cameraObservation.changed(resolvedCamera, origin: .programmatic)
        guard cameraActionRevision == motion.revision else { return }
        cameraChangeAction?.action(resolvedCamera)
        guard cameraActionRevision == motion.revision else { return }
        if progress == 1 { finishCameraMotion(motion) }
    }

    func finishCameraMotion(_ motion: OrbitCameraMotion) {
        guard cameraActionRevision == motion.revision else { return }
        cameraMotion = nil
        cameraFocus = motion.focus
        // Loading/rolling may have replaced the active projection during a timed move.
        if let resolved = cameraPose(for: resolvedCamera) { applyPose(resolved) }
        writeCameraReadback(user: false)
        guard cameraActionRevision == motion.revision else { return }
        let final = resolvedCamera
        if let id = motion.request { cameraHost.complete(id, camera: final) }
        cameraObservation.finishedAction(final)
    }

    func receiveCameraAction(_ id: DioramaCameraRequestID, _ command: CameraCommand) {
        // Capabilities can change inside an observation callback after a receipt is accepted.
        guard !arPlacementActive else { cameraHost.complete(id, result: .cancelled(id)); return }
        // The host cancels previous action IDs; binding animations also yield to imperative actions.
        stopCameraMotion(request: nil)
        guard cameraHost.activeRequest == id else { return }
        settleCameraOwnership()
        guard cameraHost.activeRequest == id else { return }
        switch command {
        case .camera(let camera, let transition):
            guard let pose = cameraPose(for: camera) else {
                cameraHost.complete(id, result: .requiresGroundNavigation(id)); return
            }
            moveCamera(to: pose, focus: camera.focus, transition: transition, request: id)
        case .reset:
            let camera = homeCamera ?? DioramaCamera()
            guard let pose = cameraPose(for: camera) else {
                cameraHost.complete(id, result: .requiresGroundNavigation(id)); return
            }
            moveCamera(to: pose, focus: camera.focus, transition: cameraTransition, request: id)
        case .fit(let target, let padding, let transition):
            let revision = cameraActionRevision
            cameraFitTask = Task { [weak self] in
                guard let self else { return }
                if case .contentIDs = target, let root = self.store.dioramaEntity as? DioramaEntity { await root.overlayRenderer.waitUntilIdle() }
                guard !Task.isCancelled, self.cameraActionRevision == revision, self.cameraHost.activeRequest == id else { return }
                self.cameraFitTask = nil
                switch self.fitCamera(target: target, padding: padding) {
                case .success(let pose):
                    let focus = self.geographicFocus(for: pose.target) ?? .chunkCenter
                    self.moveCamera(to: pose, focus: focus, transition: transition, request: id)
                case .failure(let error):
                    self.cameraHost.complete(id, result: error == .outside ? .requiresGroundNavigation(id) : error == .missing ? .invalidTarget(id) : .constrainedFit(id))
                }
            }
        }
    }

    func frameAutomaticCamera() {
        guard !arPlacementActive, !transition.isShowingGlobe, let _ = store.dioramaEntity else { return }
        if case .success(let pose) = fitCamera(target: .chunk, padding: .init(top: 24, leading: 24, bottom: 24, trailing: 24)) {
            applyPose(pose)
            cameraFocus = geographicFocus(for: pose.target) ?? .chunkCenter
            writeCameraReadback(user: false)
            if homeCamera == nil { homeCamera = resolvedCamera }
        }
    }

    enum FitError: Error { case outside, missing, constrained }

    func fitCamera(target: DioramaCameraFitTarget, padding: EdgeInsets) -> Result<DioramaCameraPose, FitError> {
        guard let root = store.dioramaEntity as? DioramaEntity else { return .failure(.missing) }
        var points: [SIMD3<Float>] = []
        func addCoordinates(_ coordinates: [Coordinate], altitude: AltitudeReference) -> Bool {
            guard let projection = store.projection else { return false }
            for source in coordinates {
                let coordinate = cameraCoordinate(source)
                let horizontal = projection.point(for: coordinate)
                guard store.configuration.boundary.contains(horizontal), let p = projection.position(for: coordinate, altitude: altitude), finite(p) else { return false }
                points.append(p * entityScale)
            }
            return true
        }
        func containsPath(_ coordinates: [Coordinate], closed: Bool) -> Bool {
            guard let projection = store.projection else { return false }
            return DioramaCameraGeometry.contains(coordinates.map { projection.point(for: cameraCoordinate($0)) },
                boundary: store.configuration.boundary.vertices, closed: closed)
        }
        func containsGeometry(_ geometry: Geometry?) -> Bool {
            switch geometry {
            case .lineString(let line): return containsPath(line.coordinates, closed: false)
            case .multiLineString(let lines): return lines.lineStrings.allSatisfy { containsPath($0.coordinates, closed: false) }
            case .polygon(let polygon): return polygon.rings.allSatisfy { containsPath($0.coordinates, closed: true) }
            case .multiPolygon(let polygons): return polygons.polygons.allSatisfy { containsGeometry(.polygon($0)) }
            case .geometryCollection(let geometries): return geometries.allSatisfy { containsGeometry($0) }
            case .point(let point): return containsPath([point.coordinate], closed: false)
            case .multiPoint(let points): return points.coordinates.allSatisfy { containsPath([$0], closed: false) }
            case nil: return false
            }
        }
        switch target {
        case .chunk:
            let bounds = root.visualBounds(relativeTo: root)
            guard finite(bounds.min), finite(bounds.max) else { return .failure(.missing) }
            points = [bounds.min.x, bounds.max.x].flatMap { x in
                [bounds.min.y, bounds.max.y].flatMap { y in [bounds.min.z, bounds.max.z].map { SIMD3(x, y, $0) * entityScale } }
            }
        case .bounds(let bounds):
            let coordinates = [Coordinate(latitude: bounds.south, longitude: bounds.west), .init(latitude: bounds.north, longitude: bounds.west),
                               .init(latitude: bounds.north, longitude: bounds.east), .init(latitude: bounds.south, longitude: bounds.east)]
            guard containsPath(coordinates, closed: true), addCoordinates(coordinates, altitude: .clampToGround) else { return .failure(.outside) }
            // Include terrain relief under the requested geographic rectangle, not just its corners.
            if let buffers = root.terrain?.surfaceBuffers {
                let projected = coordinates.compactMap { store.projection?.point(for: cameraCoordinate($0)) }
                if let lowX = projected.map(\.x).min(), let highX = projected.map(\.x).max(),
                   let lowZ = projected.map(\.y).min(), let highZ = projected.map(\.y).max() {
                    points += buffers.positions.filter { (lowX...highX).contains($0.x) && (lowZ...highZ).contains($0.z) }.map { $0 * entityScale }
                }
            }
        case .contentIDs(let ids):
            var found = Set<String>()
            for item in content?.items ?? [] {
                guard case .annotation(let feature) = item, ids.contains(feature.id) else { continue }
                found.insert(feature.id)
                var coordinates = feature.feature.geometry?.coordinates ?? []
                if case .circle(let center, let radius) = feature.overlay {
                    coordinates = (0..<64).map { Turf.destination(from: center, meters: radius, bearing: Double($0) * 360 / 64) }
                }
                let contained: Bool
                if case .circle = feature.overlay { contained = containsPath(coordinates, closed: true) }
                else { contained = containsGeometry(feature.feature.geometry) }
                guard contained, addCoordinates(coordinates, altitude: feature.style.altitude) else { return .failure(.outside) }
            }
            for (key, marker) in root.markerEntities {
                let identity = marker.components[DioramaMarkerIdentity.self]?.annotationID ?? key
                guard ids.contains(identity) else { continue }
                found.insert(identity)
                points.append(marker.position * entityScale)
                let b = marker.visualBounds(relativeTo: root)
                points += [b.min, b.max].map { $0 * entityScale }
            }
            for record in root.overlayRenderer.records.values {
                let id = record.input.annotation.selectionAnnotationID ?? record.input.annotation.id
                guard ids.contains(id) else { continue }
                found.insert(id)
                var coordinates = record.input.annotation.feature.geometry?.coordinates ?? []
                if case .circle(let center, let radius) = record.input.shape {
                    coordinates = (0..<64).map { Turf.destination(from: center, meters: radius, bearing: Double($0) * 360 / 64) }
                }
                guard addCoordinates(coordinates, altitude: record.input.annotation.style.altitude) else { return .failure(.outside) }
                for part in record.layers.values { points += part.mesh.positions.map { $0 * entityScale } }
            }
            guard found == Set(ids) else { return .failure(.missing) }
        }
        let padding = EdgeInsets(top: padding.top + cameraSafeAreaInsets.top + cameraControlInsets.top + cameraFitInsets.top,
            leading: padding.leading + cameraSafeAreaInsets.leading + cameraControlInsets.leading + cameraFitInsets.leading,
            bottom: padding.bottom + cameraSafeAreaInsets.bottom + cameraControlInsets.bottom + cameraFitInsets.bottom,
            trailing: padding.trailing + cameraSafeAreaInsets.trailing + cameraControlInsets.trailing + cameraFitInsets.trailing)
        guard let pose = DioramaCameraGeometry.fit(points: points, pose: cameraPose, viewport: viewSize, padding: padding, limits: cameraLimits) else { return .failure(.constrained) }
        if cameraLimits.focusPolicy == .insideChunk,
           !store.configuration.boundary.contains(SIMD2(pose.target.x, pose.target.z) / entityScale) { return .failure(.constrained) }
        return .success(pose)
    }

    private func cameraCoordinate(_ source: Coordinate) -> Coordinate {
        let reference: Double
        if let terrain = store.projection as? TerrainProjection {
            reference = terrain.anchor.coordinate(forDioramaX: Double(terrain.panOffset.x), z: Double(terrain.panOffset.y)).longitude
        } else { reference = store.configuration.center.longitude }
        var coordinate = source
        coordinate.longitude = reference + (source.longitude - reference).remainder(dividingBy: 360)
        return coordinate
    }

    private func finite(_ value: SIMD3<Float>) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
}
#endif
