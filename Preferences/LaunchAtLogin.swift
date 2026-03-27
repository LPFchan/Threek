import ServiceManagement
import Foundation

// ---------------------------------------------------------------------------
// MARK: - LaunchAtLogin
// ---------------------------------------------------------------------------
// Thin wrapper around SMAppService (macOS 13+).
// The main app registers itself — no helper bundle needed.
// ---------------------------------------------------------------------------

enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Toggles launch-at-login on or off.
    static func toggle() {
        if isEnabled {
            disable()
        } else {
            enable()
        }
    }

    // MARK: - Private

    static func enable() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            print("[LaunchAtLogin] Failed to enable: \(error.localizedDescription)")
        }
    }

    static func disable() {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            print("[LaunchAtLogin] Failed to disable: \(error.localizedDescription)")
        }
    }
}
