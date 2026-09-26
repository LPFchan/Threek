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
    enum Automation: String, Equatable { case allowed, denied, notAsked, notRunning }

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
        let state: Automation
        switch AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask) {
        case noErr: state = .allowed
        case OSStatus(errAEEventNotPermitted): state = .denied
        case OSStatus(errAEEventWouldRequireUserConsent): state = .notAsked
        default: state = .notRunning
        }
        remember(state, for: bundleID)
        return state
    }

    // macOS can only answer for a running app, so the last answer seen for
    // each player is kept; a stopped player is judged by that.
    private static let knownKey = "automationKnown"
    private static let knownLock = NSLock()

    private static func remember(_ state: Automation, for bundleID: String) {
        guard state != .notRunning else { return }
        knownLock.lock(); defer { knownLock.unlock() }
        var known = UserDefaults.standard.dictionary(forKey: knownKey) as? [String: String] ?? [:]
        known[bundleID] = state.rawValue
        UserDefaults.standard.set(known, forKey: knownKey)
    }

    /// The live answer if the player is running, else the last one seen
    /// (never seen counts as not asked).
    static func bestKnown(_ bundleID: String) -> Automation {
        let live = automation(bundleID, ask: false)
        guard live == .notRunning else { return live }
        knownLock.lock(); defer { knownLock.unlock() }
        let known = UserDefaults.standard.dictionary(forKey: knownKey) as? [String: String] ?? [:]
        return known[bundleID].flatMap(Automation.init(rawValue:)) ?? .notAsked
    }

    /// Everything, checked once: one checker process for Accessibility and
    /// Screen Recording, plus an Automation answer per installed player.
    /// Calls into other processes; keep it off the main thread.
    struct Snapshot {
        var accessibility: Bool
        var screen: Bool
        var automation: [String: Automation]

        /// Grant keys ("accessibility", "screen", "automation:<bundle id>").
        var granted: Set<String> {
            var keys = Set(automation.filter { $0.value == .allowed }.map { "automation:\($0.key)" })
            if accessibility { keys.insert("accessibility") }
            if screen { keys.insert("screen") }
            return keys
        }

        /// The first step with anything not granted (for the menu).
        var missing: Onboarding.Step? {
            if !accessibility { return .accessibility }
            if !screen { return .screenRecording }
            if automation.values.contains(where: { $0 != .allowed }) { return .automation }
            return nil
        }

        /// Like `missing`, but a player the user already said no to doesn't
        /// count, so a deliberate "Don't Allow" doesn't reopen setup at every
        /// launch.
        var unanswered: Onboarding.Step? {
            if !accessibility { return .accessibility }
            if !screen { return .screenRecording }
            if automation.values.contains(.notAsked) { return .automation }
            return nil
        }
    }

    static func snapshot() -> Snapshot {
        let (accessibility, screen) = PermissionCheck.both()
        var automation: [String: Automation] = [:]
        for id in installedPlayers { automation[id] = bestKnown(id) }
        return Snapshot(accessibility: accessibility, screen: screen, automation: automation)
    }
}
