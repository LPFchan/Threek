import AppKit
import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - PopupController
// ---------------------------------------------------------------------------
// Manages the floating NSPanel that hosts the SelectorPopup SwiftUI view.
// Non-activating: never steals focus from the user's current app.
// ---------------------------------------------------------------------------

@MainActor
final class PopupController {

    // MARK: - Public state
    var isShowing: Bool { panel?.isVisible ?? false }

    // Callback wired by AppDelegate
    var onDispatch: ((String) -> Void)?

    // MARK: - Private
    private var panel: NSPanel?
    private lazy var viewModel = SelectorViewModel()
    private var hostingView: NSHostingView<SelectorPopupWrapper>?

    // MARK: - Init

    init() {
        viewModel.onDispatch = { [weak self] bundleID in
            self?.animateDismiss()
            self?.onDispatch?(bundleID)
        }
        viewModel.onDismiss = { [weak self] in
            self?.animateDismiss()
        }
    }

    // MARK: - Show / Refresh / Dismiss

    func show(apps: [NowPlayingApp]) {
        if panel == nil { buildPanel() }
        viewModel.present(apps: apps)
        guard let panel else { return }

        // Position centered on the main screen
        if let screen = NSScreen.main {
            let pSize = preferredSize(apps: apps)
            let x = screen.frame.midX - pSize.width / 2
            let y = screen.frame.midY - pSize.height / 2
            panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: pSize), display: false)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func refresh(apps: [NowPlayingApp]) {
        viewModel.refresh(apps: apps)
    }

    func dismiss() {
        animateDismiss()
    }

    /// Route a key press into the view model while the popup is visible.
    func handleKey(_ event: MediaKeyEvent) {
        viewModel.handleKey(event)
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false

        // Host the SwiftUI view
        let wrapper = SelectorPopupWrapper(viewModel: viewModel)
        let hosting = NSHostingView(rootView: wrapper)
        hosting.frame = p.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        hostingView = hosting

        // Dismiss on click-outside
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: p
        )

        panel = p
    }

    @objc private func windowDidResignKey(_ note: Notification) {
        // Only dismiss if the popup yielded key focus (rare — it's non-activating,
        // but can happen if user clicks another window forcefully)
        guard panel?.isVisible == true else { return }
        viewModel.dismiss()
    }

    // MARK: - Dismiss animation

    private func animateDismiss() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: - Size hints

    private func preferredSize(apps: [NowPlayingApp]) -> NSSize {
        // Each icon slot is ~100 wide (76 icon + 24 gap), plus 40 padding
        let slots = min(apps.count, 5)  // cap display width at 5 icons visible
        let width = max(Double(slots) * 100, 220.0) + 40
        let height: Double = apps.count >= 4 ? 160 : 130
        return NSSize(width: width, height: height)
    }
}

// ---------------------------------------------------------------------------
// MARK: - SelectorPopupWrapper
// ---------------------------------------------------------------------------
// Thin wrapper so PopupController can pass the viewModel without making
// SelectorPopup generic.

private struct SelectorPopupWrapper: View {
    @ObservedObject var viewModel: SelectorViewModel

    var body: some View {
        SelectorPopup(viewModel: viewModel)
    }
}
