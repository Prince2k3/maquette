import SwiftUI

/// Keeps the caller's view at a stable SwiftUI identity even while its layout is hidden.
struct DioramaAnnotationLabel: View {
    let record: DioramaAnnotationRegistry.Record
    let selection: DioramaSelection?
    let didSelect: () -> Void

    private var identity: DioramaMarkerIdentity {
        .init(annotationID: record.id, tag: record.feature.selectionTag, allowsLegacyID: false)
    }

    var body: some View {
        record.factory.makeView()
            .tint(record.feature.style.tint)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { geometry in geometry.size } action: { size in
                guard size.width.isFinite, size.height.isFinite, size != record.measuredSize else { return }
                record.measuredSize = size
            }
            .contentShape(Rectangle())
            // A child's Button consumes its tap before this ordinary ancestor tap gesture.
            .onTapGesture {
                selection?.toggle(identity)
                didSelect()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(record.descriptor?.title ?? "")
            .accessibilityAddTraits(selection?.isSelected(identity) == true ? [.isSelected] : [])
            .modifier(DioramaAnnotationSelectionAction(selection: selection, identity: identity, didSelect: didSelect))
    }
}

private struct DioramaAnnotationSelectionAction: ViewModifier {
    let selection: DioramaSelection?
    let identity: DioramaMarkerIdentity
    let didSelect: () -> Void
    func body(content: Content) -> some View {
        if let selection, selection.tag(for: identity) != nil {
            content.accessibilityAction(named: Text("Toggle selection")) {
                selection.toggle(identity)
                didSelect()
            }
        } else { content }
    }
}

