import Foundation
import AppKit

// ---------------------------------------------------------------------------
// MARK: - Model
// ---------------------------------------------------------------------------

/// A single app that currently has an active Now Playing media session.
struct NowPlayingApp: Identifiable, Equatable {
    let id: String          // bundle identifier, unique key
    var bundleID: String { id }
    var icon: NSImage?
    var lastActive: Date    // used for sorting; most-recently-active first
    var isPlaying: Bool

    static func == (lhs: NowPlayingApp, rhs: NowPlayingApp) -> Bool {
        lhs.id == rhs.id
    }
}
