import CoreLocation
import SwiftUI

/// Whether terrain may hide a SwiftUI annotation.
public enum DioramaAnnotationOcclusion: Sendable, Equatable {
    /// Hide the label when terrain lies between its anchor and the viewer.
    case terrain
    /// Show the label even when terrain covers its anchor.
    case alwaysVisible
}

/// How a projected screen annotation competes with other labels for space.
/// Volumetric attachments keep their physical placement; overlap avoidance requires a viewer pose.
public enum DioramaAnnotationOverlap: Sendable, Equatable {
    /// Suppress lower-priority labels whose frames overlap.
    case avoid
    /// Permit this label to overlap other labels.
    case allow
}

/// Content supporting the layout options of a SwiftUI annotation.
public protocol DioramaAnnotatableContent: DioramaContent {}

/// A native SwiftUI label attached to a geographic coordinate.
///
/// Label state follows the content's identity. Supply an `id` or declare annotations inside
/// `ForEach` when labels must retain state while their coordinates or collection order change.
/// Screen hosts admit the first 256 labels and show at most 64, ordered by visibility priority.
/// On visionOS, `annotationScale(metersPerPoint:)` controls the attachment's physical size.
/// Supply an accessible list or other navigation for places hidden by layout or occlusion.
public struct DioramaAnnotation<Label: View>: DioramaAnnotatableContent, Sendable, Equatable {
    var annotation: DioramaFeature

    /// Creates an annotation whose anchor attaches the corresponding point of its label.
    @MainActor
    public init(
        _ title: String,
        coordinate: Coordinate,
        anchor: UnitPoint = .bottom,
        id: String? = nil,
        @ViewBuilder content: @escaping @MainActor () -> Label
    ) {
        annotation = DioramaFeature(
            .point(coordinate, id: id.map { .string($0) }, properties: ["title": .string(title)]),
            id: id
        )
        annotation.viewAnnotation = DioramaAnnotationDescriptor(
            title: title, coordinate: coordinate, anchor: anchor, hasExplicitID: id != nil
        )
        annotation.viewFactory = DioramaAnnotationViewFactory { AnyView(content()) }
    }

    /// Creates an annotation at a CoreLocation coordinate.
    @MainActor
    public init(
        _ title: String,
        coordinate: CLLocationCoordinate2D,
        anchor: UnitPoint = .bottom,
        id: String? = nil,
        @ViewBuilder content: @escaping @MainActor () -> Label
    ) {
        self.init(title, coordinate: Coordinate(coordinate), anchor: anchor, id: id, content: content)
    }

    /// The annotation's renderer payload. The SwiftUI label remains isolated to the main actor.
    public var items: [DioramaContentItem] { annotation.items }
}

struct DioramaAnnotationDescriptor: Sendable, Equatable {
    var title: String
    var coordinate: Coordinate
    var anchor: UnitPoint
    var offset: CGSize = .zero
    var priority: Double = 0
    var occlusion: DioramaAnnotationOcclusion = .terrain
    var overlap: DioramaAnnotationOverlap = .avoid
    var metersPerPoint: Float = 0.001
    var hasExplicitID: Bool = false

    var isValid: Bool {
        coordinate.latitude.isFinite && (-90...90).contains(coordinate.latitude)
            && coordinate.longitude.isFinite && (-180...180).contains(coordinate.longitude)
            && (coordinate.altitude?.isFinite ?? true)
            && anchor.x.isFinite && anchor.y.isFinite
            && offset.width.isFinite && offset.height.isFinite
            && priority.isFinite && metersPerPoint.isFinite && metersPerPoint > 0
    }
}

/// Owns the actor-isolated view closure without sending a SwiftUI view across actors.
@MainActor
final class DioramaAnnotationViewFactory: Equatable {
    nonisolated let identity = UUID()
    private let content: @MainActor () -> AnyView

    init(content: @escaping @MainActor () -> AnyView) { self.content = content }
    func makeView() -> AnyView { content() }

    nonisolated static func == (lhs: DioramaAnnotationViewFactory, rhs: DioramaAnnotationViewFactory) -> Bool {
        lhs.identity == rhs.identity
    }
}

/// An annotation carrying a layout option. Produced by the annotation modifiers.
public struct DioramaAnnotationStyledContent<Content: DioramaAnnotatableContent>: DioramaAnnotatableContent {
    let content: Content
    let option: DioramaAnnotationOption

    public var items: [DioramaContentItem] {
        content.items.map { item in
            guard case .annotation(var feature) = item, var descriptor = feature.viewAnnotation else { return item }
            switch option {
            case .offset(let value): descriptor.offset = value
            case .priority(let value): descriptor.priority = value
            case .occlusion(let value): descriptor.occlusion = value
            case .overlap(let value): descriptor.overlap = value
            case .scale(let value): descriptor.metersPerPoint = value
            }
            feature.viewAnnotation = descriptor
            return .annotation(feature)
        }
    }
}

enum DioramaAnnotationOption {
    case offset(CGSize)
    case priority(Double)
    case occlusion(DioramaAnnotationOcclusion)
    case overlap(DioramaAnnotationOverlap)
    case scale(Float)
}

extension DioramaAnnotatableContent {
    /// Offsets a label from its projected anchor, in SwiftUI points.
    public func annotationOffset(x: CGFloat = 0, y: CGFloat = 0) -> DioramaAnnotationStyledContent<Self> {
        DioramaAnnotationStyledContent(content: self, option: .offset(CGSize(width: x, height: y)))
    }
    /// Gives higher-priority screen labels preference when avoiding overlaps.
    public func annotationPriority(_ value: Double) -> DioramaAnnotationStyledContent<Self> {
        DioramaAnnotationStyledContent(content: self, option: .priority(value))
    }
    /// Chooses whether terrain may cover this label.
    public func annotationOcclusion(_ value: DioramaAnnotationOcclusion) -> DioramaAnnotationStyledContent<Self> {
        DioramaAnnotationStyledContent(content: self, option: .occlusion(value))
    }
    /// Chooses whether this screen label may overlap other labels.
    public func annotationOverlap(_ value: DioramaAnnotationOverlap) -> DioramaAnnotationStyledContent<Self> {
        DioramaAnnotationStyledContent(content: self, option: .overlap(value))
    }
    /// Sets the size of one SwiftUI point in physical metres on visionOS.
    public func annotationScale(metersPerPoint: Float = 0.001) -> DioramaAnnotationStyledContent<Self> {
        DioramaAnnotationStyledContent(content: self, option: .scale(metersPerPoint))
    }
}

extension DioramaStyledContent: DioramaAnnotatableContent where Content: DioramaAnnotatableContent {}
extension DioramaIdentifiedContent: DioramaAnnotatableContent where Content: DioramaAnnotatableContent {}
