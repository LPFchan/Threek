import AppKit
import PermissionFlow

/// One shared PermissionFlow controller, so the onboarding and the menu bar
/// actions reuse a single floating drag panel for permission grants.
@MainActor
enum Permissions {
    /// No system prompt: the drag panel is how Threek gets into the list,
    /// and a prompt on top of it would only compete with it.
    static let controller = PermissionFlow.makeController(
        configuration: .init(
            requiredAppURLs: [Bundle.main.bundleURL],
            promptForAccessibilityTrust: false))

    /// Opens the Accessibility pane in System Settings with the floating
    /// drag-the-app panel anchored next to it.
    static func openAccessibility(sourceFrameInScreen: CGRect? = nil) {
        let frame = sourceFrameInScreen ?? {
            let mouse = NSEvent.mouseLocation
            return CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32)
        }()
        controller.authorize(pane: .accessibility, sourceFrameInScreen: frame)
    }
}

extension Permissions {
    /// Opens Privacy & Security > Screen & System Audio Recording with the
    /// drag-the-app panel.
    static func openScreenRecording() {
        let mouse = NSEvent.mouseLocation
        controller.authorize(pane: .screenRecording,
                             sourceFrameInScreen: CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32))
    }

    /// Opens Privacy & Security > Automation, where each app's switch lives.
    static func openAutomation() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}

/// What Threek needs from macOS, and whether it has it. Accessibility
/// catches the media keys, Screen Recording lets the HUD pick readable text
/// for what's behind it, and Automation (asked per app) sends it commands.
enum PermissionStatus {
    enum Automation: Equatable { case allowed, denied, notAsked, notRunning }

    /// Supported players that are installed, in a stable order.
    static var installedPlayers: [String] {
        (NowPlayingService.scriptableBundleIDs.union([QuickTimeDocuments.bundleID]))
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            .sorted()
    }

    static var accessibility: Bool { MediaKeyInterceptor.hasAccessibility() }
    static var screenRecording: Bool { PermissionCheck.has(.screen) }

    /// Asks macOS whether Threek may send Apple events to `bundleID`. With
    /// `ask`, shows the consent prompt if it hasn't been answered, and blocks
    /// until it is, so call it off the main thread. Needs the app running.
    static func automation(_ bundleID: String, ask: Bool) -> Automation {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        switch AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .notRunning
        }
    }

    /// The grants Threek has right now, as keys ("accessibility",
    /// "screen", "automation:<bundle id>"). Automation is only knowable for
    /// running apps. Calls into other apps; keep it off the main thread.
    static func granted() -> Set<String> {
        var keys = Set<String>()
        if accessibility { keys.insert("accessibility") }
        if screenRecording { keys.insert("screen") }
        for id in installedPlayers where automation(id, ask: false) == .allowed {
            keys.insert("automation:\(id)")
        }
        return keys
    }

    /// The first onboarding step whose permission is missing, or nil when
    /// everything that can be checked is granted. Off the main thread.
    static func firstMissingStep() -> Onboarding.Step? {
        if !accessibility { return .accessibility }
        if !screenRecording { return .screenRecording }
        if installedPlayers.contains(where: {
            let state = automation($0, ask: false)
            return state == .denied || state == .notAsked
        }) { return .automation }
        return nil
    }
}
