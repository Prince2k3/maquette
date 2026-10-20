import SwiftUI

/// Non-rendering API prototype. Never forwards unsupported new content to the production renderer.
@MainActor
public struct DioramaView: View {
    enum GroundInput {
        case initial(DioramaRegion)
        case controlled(Binding<DioramaGroundPosition>)
    }
    enum CameraInput {
        case initial(DioramaCameraPosition)
        case controlled(Binding<DioramaCameraPosition>)
    }
    let ground: GroundInput
    let camera: CameraInput
    let interactionModes: DioramaInteractionModes
    let content: DioramaContentGroup
    let selection: SelectionBinding?

    public init(initialRegion: DioramaRegion, initialCamera: DioramaCameraPosition = .automatic,
                interactionModes: DioramaInteractionModes = .all,
                @DioramaContentBuilder content: () -> DioramaContentGroup = { DioramaContentGroup {} }) {
        ground = .initial(initialRegion); camera = .initial(initialCamera)
        self.interactionModes = interactionModes; selection = nil; self.content = content()
    }
    public init<Selection: Hashable & Sendable>(initialRegion: DioramaRegion,
                initialCamera: DioramaCameraPosition = .automatic, interactionModes: DioramaInteractionModes = .all,
                selection: Binding<Selection?>,
                @DioramaContentBuilder content: () -> DioramaContentGroup = { DioramaContentGroup {} }) {
        ground = .initial(initialRegion); camera = .initial(initialCamera); self.interactionModes = interactionModes
        self.selection = SelectionBinding(selection); self.content = content()
    }
    public init(initialRegion: DioramaRegion, cameraPosition: Binding<DioramaCameraPosition>,
                interactionModes: DioramaInteractionModes = .all,
                @DioramaContentBuilder content: () -> DioramaContentGroup = { DioramaContentGroup {} }) {
        ground = .initial(initialRegion); camera = .controlled(cameraPosition)
        self.interactionModes = interactionModes; selection = nil; self.content = content()
    }
    public init<Selection: Hashable & Sendable>(initialRegion: DioramaRegion,
                cameraPosition: Binding<DioramaCameraPosition>, interactionModes: DioramaInteractionModes = .all,
                selection: Binding<Selection?>,
                @DioramaContentBuilder content: () -> DioramaContentGroup = { DioramaContentGroup {} }) {
        ground = .initial(initialRegion); camera = .controlled(cameraPosition)
        self.interactionModes = interactionModes; self.selection = SelectionBinding(selection); self.content = content()
    }
    public init(groundPosition: Binding<DioramaGroundPosition>, initialCamera: DioramaCameraPosition = .automatic,
                interactionModes: DioramaInteractionModes = .all,
                @DioramaContentBuilder content: () -> DioramaContentGroup = { DioramaContentGroup {} }) {
        ground = .controlled(groundPosition); camera = .initial(initialCamera)
        self.interactionModes = interactionModes; selection = nil; self.content = content()
    }
    public init<Selection: Hashable & Sendable>(groundPosition: Binding<DioramaGroundPosition>,
                initialCamera: DioramaCameraPosition = .automatic, interactionModes: DioramaInteractionModes = .all,
                selection: Binding<Selection?>,
                @DioramaContentBuilder content: () -> DioramaContentGroup = { DioramaContentGroup {} }) {
        ground = .controlled(groundPosition); camera = .initial(initialCamera); self.interactionModes = interactionModes
        self.selection = SelectionBinding(selection); self.content = content()
    }
    public init(groundPosition: Binding<DioramaGroundPosition>, cameraPosition: Binding<DioramaCameraPosition>,
                interactionModes: DioramaInteractionModes = .all,
                @DioramaContentBuilder content: () -> DioramaContentGroup = { DioramaContentGroup {} }) {
        ground = .controlled(groundPosition); camera = .controlled(cameraPosition)
        self.interactionModes = interactionModes; selection = nil; self.content = content()
    }
    public init<Selection: Hashable & Sendable>(groundPosition: Binding<DioramaGroundPosition>,
                cameraPosition: Binding<DioramaCameraPosition>, interactionModes: DioramaInteractionModes = .all,
                selection: Binding<Selection?>,
                @DioramaContentBuilder content: () -> DioramaContentGroup = { DioramaContentGroup {} }) {
        ground = .controlled(groundPosition); camera = .controlled(cameraPosition)
        self.interactionModes = interactionModes; self.selection = SelectionBinding(selection); self.content = content()
    }
    public var body: some View {
        Text("Maquette API contract prototype — rendering is not connected")
    }
}

@MainActor
struct SelectionBinding {
    let read: () -> TypedValue?
    let write: (TypedValue?) -> Void
    init<Value: Hashable & Sendable>(_ binding: Binding<Value?>) {
        read = { binding.wrappedValue.map(TypedValue.init) }
        write = { tag in
            guard let tag else { binding.wrappedValue = nil; return }
            guard tag.type == ObjectIdentifier(Value.self), let value = tag.value.base as? Value else { return }
            binding.wrappedValue = value
        }
    }
}

/// Creates one command scope. The prototype deliberately has no rendering action receiver.
@MainActor
public struct DioramaReader<Content: View>: View {
    @State private var host = CameraActionHost()
    let content: (DioramaCameraProxy) -> Content
    public init(@ViewBuilder content: @escaping @MainActor (DioramaCameraProxy) -> Content) { self.content = content }
    public var body: some View { content(DioramaCameraProxy(host: host)) }
}
