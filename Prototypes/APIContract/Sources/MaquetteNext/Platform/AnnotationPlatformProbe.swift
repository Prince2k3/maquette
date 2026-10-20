import RealityKit
import SwiftUI
#if canImport(_RealityKit_SwiftUI)
@preconcurrency import _RealityKit_SwiftUI
#endif

// Compiled against the deployment floors, not a new-only API hidden behind availability checks.
#if os(iOS) || os(macOS)
@MainActor
func projectAnnotationAnchor(_ point: SIMD3<Float>, content: RealityViewCameraContent) -> CGPoint? {
    content.project(point: point, to: .local)
}
#endif

#if os(visionOS)
@MainActor
struct AnnotationAttachmentProbe: View {
    var body: some View {
        RealityView { content, attachments in
            if let label = attachments.entity(for: "annotation") { content.add(label) }
        } attachments: {
            Attachment(id: "annotation") { Text("Terrain label") }
        }
    }
}
#endif
