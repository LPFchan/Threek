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
    /// Whether this app is actually playing right now, from the Now Playing
    /// registry's per-app playback rate (> 0). Nil when the metadata fetch
    /// didn't cover this app, in which case it's treated as not playing —
    /// the direct-dispatch shortcut only fires on a confirmed playing app.
    var isPlaying: Bool?
    /// Whether the metadata fetch actually returned this track's info. When
    /// true and `artwork` is nil, the track genuinely has no artwork (so the
    /// cache must not resurrect an older image). When false, artwork may just
    /// not have arrived yet, so a cached image for the same track stays valid.
    var metadataAvailable: Bool = false
    /// Set for a QuickTime Player entry: QuickTime is listed once per open
    /// document, and commands target that document (QuickTimeDocuments).
    var document: QuickTimeDocuments.Document?

    var id: String {
        document.map { "\(effectiveBundleID)#\($0.key)" } ?? effectiveBundleID
    }

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
        lhs.id == rhs.id && lhs.artwork == rhs.artwork
            && lhs.trackTitle == rhs.trackTitle
            && lhs.metadataAvailable == rhs.metadataAvailable
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(trackTitle)
    }
}
