import os

extension Logger {
    /// The subsystem every logger in the package reports under.
    static let maquetteSubsystem = "com.maquette"

    /// Creates a logger in the package's subsystem.
    ///
    /// One spelling for every logger, so `log show --predicate 'subsystem == "com.maquette"'`
    /// catches all of it and a category can never drift from the type it names.
    init(maquette category: String) {
        self.init(subsystem: Logger.maquetteSubsystem, category: category)
    }
}
