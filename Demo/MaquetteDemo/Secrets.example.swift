import Foundation

/// Credentials for the demo. Copy to `Secrets.swift` and fill in — that file is gitignored.
///
/// Keys are kept out of source control deliberately: a credential written into a committed file
/// is published for as long as the commit that added it exists, and deleting it later does not
/// unpublish it.
enum Secrets {
    /// Google Maps Platform API key with the Map Tiles API enabled.
    ///
    /// Google bills the root tileset request only, so the demo costs roughly one billable event
    /// per load — and the provider caches the root, so repeated launches are free.
    static let googleMapsAPIKey = ""
}
