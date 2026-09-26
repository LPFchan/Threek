import Foundation

/// User settings, kept in UserDefaults.
enum Preferences {
    static let showArtworkKey = "showArtwork"

    /// Show album artwork in the HUD, with the app icon as a corner badge.
    /// Off shows only app icons. On by default.
    static var showArtwork: Bool {
        get { UserDefaults.standard.object(forKey: showArtworkKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showArtworkKey) }
    }
}
