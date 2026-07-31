import AppKit

/// A single app registered with macOS Now Playing (playing or paused).
struct NowPlayingApp: Identifiable, Equatable, Hashable {
    let bundleID: String
    let displayName: String
    let processIdentifier: pid_t?
    /// Set when the Now Playing entry belongs to a child/helper process
    /// (e.g. a WebKit GPU process for a browser tab). The parent bundle ID is
    /// what should be targeted and shown.
    let parentBundleID: String?
    /// Whether picking this app will reliably reach it. Scriptable apps
    /// (Music, Spotify) are always controllable via AppleScript; non-scriptable
    /// apps (browsers, Zen) are only controllable while they're the current
    /// now-playing app, where the adapter can reach them. Non-controllable apps
    /// are shown greyed-out and can't be picked.
    var isControllable: Bool = true
    /// The app's current album artwork, when the Now Playing registry has it.
    /// Nil for apps that publish no artwork (web media, squatters); the picker
    /// falls back to the app icon in that case.
    var artwork: NSImage?
    /// The current track title, when available. Shown as the picker's tooltip
    /// alongside the app name so artwork-bearing rows stay identifiable.
    var trackTitle: String?

    var id: String { effectiveBundleID }

    /// The bundle ID to show and to send commands to — the parent's when this
    /// is a helper process, otherwise our own.
    var effectiveBundleID: String { parentBundleID ?? bundleID }

    var icon: NSImage? {
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: effectiveBundleID).first {
            return running.icon
        }
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: effectiveBundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    static func == (lhs: NowPlayingApp, rhs: NowPlayingApp) -> Bool {
        lhs.id == rhs.id && lhs.artwork == rhs.artwork && lhs.trackTitle == rhs.trackTitle
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(trackTitle)
    }
}
