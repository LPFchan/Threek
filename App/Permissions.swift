import AppKit
import PermissionFlow

/// One shared PermissionFlow controller, so the onboarding and the menu bar
/// actions reuse a single floating drag panel for permission grants.
@MainActor
enum Permissions {
    /// `promptForAccessibilityTrust` keeps the one-time system prompt on the
    /// paths that relied on `AXIsProcessTrustedWithOptions` before.
    static let controller = PermissionFlow.makeController(
        configuration: .init(
            requiredAppURLs: [Bundle.main.bundleURL],
            promptForAccessibilityTrust: true))

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
