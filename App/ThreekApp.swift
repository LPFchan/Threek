import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - ThreekApp
// ---------------------------------------------------------------------------
// @main entry point. Uses NSApplicationDelegateAdaptor so AppDelegate
// owns the menu bar, event tap, and popup controller.
// The app has LSUIElement=true (no Dock icon) set in Info.plist.
// ---------------------------------------------------------------------------

@main
struct ThreekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No windows — this is a menu-bar-only app.
        // We suppress the default empty window by using Settings scene
        // as a no-op; actual UI lives in AppDelegate.
        Settings {
            EmptyView()
        }
    }
}
