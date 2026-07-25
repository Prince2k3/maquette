import Foundation

/// Credentials for the demo. Copy to `Secrets.swift` and fill in — that file is gitignored.
///
/// Keys are kept out of source control deliberately: two credentials are already exposed in this
/// repository's history and adding a third would compound it.
enum Secrets {
    /// Google Maps Platform API key with the Map Tiles API enabled.
    ///
    /// Google bills the root tileset request only, so the demo costs roughly one billable event
    /// per load — and the provider caches the root, so repeated launches are free.
    static let googleMapsAPIKey = ""
}
