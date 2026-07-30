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
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
