import AppKit
import SwiftUI
import ServiceManagement

// ---------------------------------------------------------------------------
// MARK: - AppDelegate
// ---------------------------------------------------------------------------
// Owns: NSStatusItem (menu bar), MediaKeyInterceptor, PopupController.
// Routes media key presses → NowPlayingService → popup or pass-through.
// ---------------------------------------------------------------------------

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Dependencies
    private let interceptor = MediaKeyInterceptor()
    private let popupController = PopupController()

    // MARK: - Menu bar
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    // MARK: - State
    private var isEnabled = true  // Toggle to pass all keys through

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock (belt-and-suspenders; LSUIElement covers this)
        NSApp.setActivationPolicy(.accessory)

        // Wire popup dispatch → NowPlayingService
        popupController.onDispatch = { bundleID in
            NowPlayingService.shared.sendPlayPause(to: bundleID)
        }

        setupMenuBar()
        checkAccessibilityAndStart()
        observeApplicationTerminations()
    }

    func applicationWillTerminate(_ notification: Notification) {
        interceptor.stop()
    }

    // MARK: - Accessibility check

    private func checkAccessibilityAndStart() {
        if AXIsProcessTrusted() {
            startInterceptor()
            return
        }

        // Not yet granted. Fire the system TCC prompt once — macOS shows
        // "Threek wants to control your computer" the first time only.
        // NOTE: after a debug rebuild the binary hash changes so TCC may
        // show the toggle as ON but return false here. In that case,
        // toggle Threek OFF then ON again in System Settings to re-grant.
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
        ]
        AXIsProcessTrustedWithOptions(options)
        updateMenuBarIcon(trusted: false)
        pollForAccessibility()
    }

    private func pollForAccessibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.updateMenuBarIcon(trusted: true)
                self.startInterceptor()
            } else {
                self.pollForAccessibility()
            }
        }
    }

    private func startInterceptor() {
        interceptor.onKeyDown = { [weak self] event in
            self?.handleMediaKey(event) ?? false
        }
        interceptor.onTapInvalidated = { [weak self] in
            self?.handleTapInvalidated()
        }
        interceptor.start()
        // Only mark trusted if the tap actually created successfully.
        // start() prints a failure message if it can't create the tap.
        // Give the run loop one cycle to settle, then poll the real state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            if self.interceptor.isRunning {
                self.updateMenuBarIcon(trusted: true)
            } else {
                // Tap creation failed despite AXIsProcessTrusted() returning true.
                // This can happen when TCC hasn't fully propagated. Re-poll.
                self.updateMenuBarIcon(trusted: false)
                self.pollForAccessibility()
            }
        }
    }

    private func handleTapInvalidated() {
        // The CGEvent tap was torn down (usually because Accessibility was revoked).
        // Stop cleanly and re-poll; the interceptor will restart automatically once
        // the user re-grants access in System Settings.
        interceptor.stop()
        updateMenuBarIcon(trusted: false)
        pollForAccessibility()
    }

    // MARK: - Media key routing

    /// Returns true to consume the event, false to let it pass through.
    @discardableResult
    private func handleMediaKey(_ event: MediaKeyEvent) -> Bool {
        guard isEnabled else { return false }  // Pass-through mode

        // ⏮/⏭ always pass through (spec)
        guard event == .playPause else { return false }

        // If popup is already showing (4+ app selector), route keys into it
        if popupController.isShowing {
            popupController.handleKey(event)
            return true
        }

        // Fetch then decide; completion fires on main queue
        NowPlayingService.shared.fetchApps { [weak self] apps in
            guard let self else { return }
            print("[AppDelegate] handleMediaKey: fetchApps returned \(apps.count) app(s): \(apps.map(\.bundleID))")
            if apps.count <= 1 {
                print("[AppDelegate] handleMediaKey: ≤ 1 app, re-injecting key")
                self.passPlayPauseThroughToSystem()
            } else {
                print("[AppDelegate] handleMediaKey: \(apps.count) apps, showing popup")
                self.popupController.show(apps: apps)
            }
        }
        // Consume the original event; we'll re-inject if needed
        return true
    }

    /// Re-injects a play/pause hardware key event so the system handles it normally.
    private func passPlayPauseThroughToSystem() {
        // Post a fake NSSystemDefined play/pause event
        // subtype 8, data1 = (NX_KEYTYPE_PLAY << 16) | 0x0100 (key down flag = 0, play key)
        let keyDown = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (16 << 16) | 0x0000,  // NX_KEYTYPE_PLAY, key-down flag clear
            data2: -1
        )
        keyDown?.cgEvent?.post(tap: .cghidEventTap)

        let keyUp = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (16 << 16) | 0x0100,  // NX_KEYTYPE_PLAY, key-up flag set
            data2: -1
        )
        keyUp?.cgEvent?.post(tap: .cghidEventTap)
    }

    // MARK: - NSWorkspace notification

    private func observeApplicationTerminations() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc private func applicationTerminated(_ note: Notification) {
        guard popupController.isShowing else { return }
        NowPlayingService.shared.fetchApps { [weak self] apps in
            guard let self else { return }
            if apps.count <= 1 {
                self.popupController.dismiss()
            } else {
                self.popupController.refresh(apps: apps)
            }
        }
    }

    // MARK: - Accessibility alert

    // MARK: - Menu bar setup

    /// Updates the status bar icon to indicate whether Accessibility is granted.
    /// Trusted → normal icon. Untrusted → strikethrough / warning variant.
    private func updateMenuBarIcon(trusted: Bool) {
        guard let button = statusItem?.button else { return }
        let symbolName = trusted ? "3.circle.fill" : "3.circle"
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Threek") {
            img.isTemplate = true
            button.image = img
        }
        button.toolTip = trusted ? nil : "Threek: tap menu → Grant Accessibility Access"
        // Refresh the menu so the Accessibility item title/action updates.
        buildMenu()
        statusItem?.menu = menu
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        // SF Symbol "3.circle.fill" — minimal, evocative of "Threek"
        if let image = NSImage(systemSymbolName: "3.circle.fill", accessibilityDescription: "Threek") {
            image.isTemplate = true  // Adapts to light/dark menu bar
            button.image = image
        } else {
            button.title = "3▶"
        }

        buildMenu()
        statusItem?.menu = menu
    }

    // MARK: - Menu construction

    func buildMenu() {
        let m = NSMenu(title: "Threek")

        // Enabled toggle
        let enabledItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = isEnabled ? .on : .off
        enabledItem.tag = 1
        m.addItem(enabledItem)

        m.addItem(.separator())

        // Currently Playing submenu (built lazily when user opens menu)
        let nowPlayingItem = NSMenuItem(title: "Currently Playing", action: nil, keyEquivalent: "")
        let nowPlayingSubmenu = NSMenu(title: "Currently Playing")
        nowPlayingSubmenu.addItem(NSMenuItem(title: "Loading…", action: nil, keyEquivalent: ""))
        nowPlayingItem.submenu = nowPlayingSubmenu
        m.addItem(nowPlayingItem)

        m.addItem(.separator())

        // Accessibility status / re-grant item (shown when tap is not running)
        let axItem = NSMenuItem(
            title: interceptor.isRunning ? "Accessibility: ✓ Active" : "Grant Accessibility Access…",
            action: interceptor.isRunning ? nil : #selector(resetAndPromptAccessibility),
            keyEquivalent: ""
        )
        axItem.target = self
        axItem.tag = 3
        m.addItem(axItem)

        m.addItem(.separator())

        // Launch at Login
        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        loginItem.tag = 2
        m.addItem(loginItem)

        m.addItem(.separator())

        // About
        let aboutItem = NSMenuItem(title: "About Threek", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        m.addItem(aboutItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit Threek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quitItem)

        menu = m
        m.delegate = self
    }

    // MARK: - Menu actions

    @objc private func resetAndPromptAccessibility() {
        // Reset the stale TCC entry for this bundle so macOS will prompt fresh.
        // This is needed when Xcode rebuilds the binary (new hash) but the old
        // grant is still showing in System Settings.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "Accessibility", "com.lpfchan.Threek"]
        try? proc.run()
        proc.waitUntilExit()

        // Now re-trigger the system TCC prompt.
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
        ]
        AXIsProcessTrustedWithOptions(options)
        pollForAccessibility()
    }

    @objc private func toggleEnabled(_ item: NSMenuItem) {
        isEnabled.toggle()
        item.state = isEnabled ? .on : .off
        if !isEnabled { popupController.dismiss() }
    }

    @objc private func toggleLaunchAtLogin(_ item: NSMenuItem) {
        LaunchAtLogin.toggle()
        item.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Threek 1.0"
        alert.informativeText = "Because it's funny.\n\nA macOS menu bar app that intercepts media keys and lets you choose which app receives them.\n\n© 2026 LPFchan"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - NSMenuDelegate (lazy Now Playing submenu)
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard let nowPlayingItem = menu.item(withTitle: "Currently Playing"),
              let submenu = nowPlayingItem.submenu else { return }

        submenu.removeAllItems()
        submenu.addItem(NSMenuItem(title: "Loading…", action: nil, keyEquivalent: ""))

        NowPlayingService.shared.fetchApps { apps in
            submenu.removeAllItems()
            if apps.isEmpty {
                submenu.addItem(NSMenuItem(title: "Nothing playing", action: nil, keyEquivalent: ""))
            } else {
                for app in apps {
                    let title = app.bundleID.components(separatedBy: ".").last ?? app.bundleID
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    if let icon = app.icon {
                        let img = icon.copy() as! NSImage
                        img.size = NSSize(width: 16, height: 16)
                        item.image = img
                    }
                    submenu.addItem(item)
                }
            }
        }
    }
}
