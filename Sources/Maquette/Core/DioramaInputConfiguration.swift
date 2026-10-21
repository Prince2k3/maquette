import SwiftUI

/// Which independent zoom operation an input or control requests.
public enum DioramaZoomTarget: Sendable, Equatable {
    case ground
    case camera
}

/// A scene navigation command. Pan deltas are screen points; orbit deltas are degrees.
public enum DioramaInputAction: Sendable, Equatable {
    case pan(horizontal: Float, vertical: Float)
    case orbit(heading: Double, pitch: Double)
    case zoom(DioramaZoomTarget, steps: Double)
    case north, overhead, oblique, fit, reset
}

/// A keyboard mapping active only while the diorama scene has keyboard focus.
public struct DioramaKeyboardShortcut: Sendable, Equatable {
    public var key: KeyEquivalent
    public var modifiers: EventModifiers
    public var action: DioramaInputAction
    public init(_ key: KeyEquivalent, modifiers: EventModifiers = [], action: DioramaInputAction) {
        self.key = key; self.modifiers = modifiers; self.action = action
    }

    public static let standard: [Self] = [
        .init(.leftArrow, action: .pan(horizontal: -40, vertical: 0)),
        .init(.rightArrow, action: .pan(horizontal: 40, vertical: 0)),
        .init(.upArrow, action: .pan(horizontal: 0, vertical: -40)),
        .init(.downArrow, action: .pan(horizontal: 0, vertical: 40)),
        .init(.leftArrow, modifiers: .option, action: .orbit(heading: -10, pitch: 0)),
        .init(.rightArrow, modifiers: .option, action: .orbit(heading: 10, pitch: 0)),
        .init(.upArrow, modifiers: .option, action: .orbit(heading: 0, pitch: -5)),
        .init(.downArrow, modifiers: .option, action: .orbit(heading: 0, pitch: 5)),
        .init("=", action: .zoom(.ground, steps: 1)),
        .init("+", action: .zoom(.ground, steps: 1)),
        .init("+", modifiers: .shift, action: .zoom(.ground, steps: 1)),
        .init("-", action: .zoom(.ground, steps: -1)),
        .init("=", modifiers: .option, action: .zoom(.camera, steps: 1)),
        .init("-", modifiers: .option, action: .zoom(.camera, steps: -1)),
        .init("n", action: .north), .init("o", action: .overhead),
        .init("f", action: .fit), .init("r", action: .reset)
    ]
}

/// Gesture mappings and sensitivity for a diorama, independently of its enabled permissions.
public struct DioramaInputConfiguration: Sendable, Equatable {
    public enum Preset: Sendable, Equatable { case map, legacyOrbit }
    public var preset: Preset
    /// Positive multipliers, capped at 100. Invalid values resolve to 1.
    public var panSensitivity: Float = 1
    public var orbitSensitivity: Float = 1
    public var zoomSensitivity: Float = 1
    public var wheelZoomTarget: DioramaZoomTarget = .ground
    /// Hold this modifier to use the other zoom target. Empty disables the alternate mapping.
    public var alternateWheelModifiers: EventModifiers = .shift
    public var keyboardShortcuts: [DioramaKeyboardShortcut] = DioramaKeyboardShortcut.standard

    public init(preset: Preset = .map) { self.preset = preset }
    public static let map = Self()
    public static let legacyOrbit = Self(preset: .legacyOrbit)

    var resolved: Self {
        var copy = self
        if !copy.panSensitivity.isFinite || copy.panSensitivity <= 0 { copy.panSensitivity = 1 }
        if !copy.orbitSensitivity.isFinite || copy.orbitSensitivity <= 0 { copy.orbitSensitivity = 1 }
        if !copy.zoomSensitivity.isFinite || copy.zoomSensitivity <= 0 { copy.zoomSensitivity = 1 }
        copy.panSensitivity = min(copy.panSensitivity, 100)
        copy.orbitSensitivity = min(copy.orbitSensitivity, 100)
        copy.zoomSensitivity = min(copy.zoomSensitivity, 100)
        return copy
    }
}

extension EnvironmentValues {
    @Entry var dioramaInputConfiguration = DioramaInputConfiguration.map
}
extension View {
    /// Configures this hierarchy's scene inputs. Each diorama retains its own focus and actions.
    public func dioramaInput(_ configuration: DioramaInputConfiguration) -> some View {
        environment(\.dioramaInputConfiguration, configuration)
    }
}

/// Lists the configured shortcuts without registering global keyboard handlers.
/// Commands execute only while the scene itself has focus; annotation editors keep text input.
public struct DioramaKeyboardHelp: View {
    @Environment(\.dioramaInputConfiguration) private var configuration
    public init() {}
    public var body: some View {
        Menu("Keyboard shortcuts", systemImage: "keyboard") {
            Text("Click or Tab to focus the terrain scene")
            ForEach(Array(configuration.keyboardShortcuts.enumerated()), id: \.offset) { _, shortcut in
                Text("\(shortcut.description)")
            }
        }
        .accessibilityIdentifier("diorama-keyboard-help")
    }
}

extension DioramaKeyboardShortcut {
    var description: String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }
        let name: String
        switch action {
        case .pan: name = "Pan ground"
        case .orbit: name = "Orbit camera"
        case .zoom(let target, let steps): name = "Zoom \(target == .ground ? "ground" : "camera") \(steps > 0 ? "in" : "out")"
        case .north: name = "Face north"
        case .overhead: name = "Overhead view"
        case .oblique: name = "Oblique view"
        case .fit: name = "Fit diorama"
        case .reset: name = "Reset diorama"
        }
        return "\(prefix)\(key.character) — \(name)"
    }
}
