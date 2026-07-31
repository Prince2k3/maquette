import Foundation
import SwiftUI

extension View {
    /// Performs an action when a diorama in this hierarchy changes its loading phase.
    ///
    /// The built-in overlay still shows the spinner and the retry affordance; this is for apps
    /// that want to reflect the phase elsewhere — analytics, a toolbar state, their own chrome.
    ///
    /// ```swift
    /// DioramaView(region: region)
    ///     .onDioramaLoadingChange { state in
    ///         if case .failed(let error) = state { log(error) }
    ///     }
    /// ```
    public func onDioramaLoadingChange(
        _ action: @escaping @MainActor (DioramaLoadingState) -> Void
    ) -> some View {
        environment(\.dioramaLoadingChangeAction, DioramaLoadingChangeAction(action: action))
    }
}

/// Wrapper giving the loading-change closure the `Equatable` identity `@Entry` storage wants.
struct DioramaLoadingChangeAction: Equatable {
    let id = UUID()
    let action: @MainActor (DioramaLoadingState) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension EnvironmentValues {
    @Entry var dioramaLoadingChangeAction: DioramaLoadingChangeAction? = nil
}
