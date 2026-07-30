import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let interceptor = MediaKeyInterceptor()
    private let popup = PopupController()

    private var statusItem: NSStatusItem?
    private var isEnabled = true
    private var isPolling = false
    /// True once we've confirmed the event tap actually receives events. A
    /// stale TCC grant leaves AXIsProcessTrusted()==true but the tap blind.
    private var tapVerified = false
    private var selfTestKeyCode: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popup.onDispatch = { [weak self] bundleID, key in
            DispatchQueue.main.async {
                self?.dispatch(key, to: bundleID)
            }
        }

        setupMenuBar()
        checkAccessibilityAndStart()
        NowPlayingService.shared.warmCache()
        verifyTapHealth()
    }

    func applicationWillTerminate(_ notification: Notification) {
        interceptor.stop()
    }

    // MARK: - Accessibility

    private func checkAccessibilityAndStart() {
        if AXIsProcessTrusted() {
            startInterceptor()
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        updateIcon(trusted: false)
        startPolling()
    }

    private func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        poll()
    }

    private func poll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.isPolling = false
                self.startInterceptor()
            } else {
                self.poll()
            }
        }
    }

    private func startInterceptor() {
        interceptor.onKeyDown = { [weak self] event in
            self?.handleMediaKey(event) ?? false
        }
        interceptor.onTapInvalidated = { [weak self] in
            self?.interceptor.stop()
            self?.updateIcon(trusted: false)
            self?.startPolling()
        }
        interceptor.start()
        Log.write("[AppDelegate] AXIsProcessTrusted=\(AXIsProcessTrusted()) interceptor.isRunning=\(interceptor.isRunning)")
        updateIcon(trusted: interceptor.isRunning)
        if !interceptor.isRunning { startPolling() }
    }

    // MARK: - Tap health

    /// A media key we synthesize ourselves at startup. When our own tap sees
    /// it, we know the tap is live. If it never arrives within the timeout,
    /// the Accessibility grant is stale and the user must re-toggle it.
    private func verifyTapHealth() {
        guard interceptor.isRunning else { return }
        // Use the EJECT key (14) — it has no system effect, so it's a safe
        // canary that won't disturb playback even if it leaks through.
        let keyCode: Int32 = 14
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.selfTestKeyCode = keyCode
            Self.postSystemDefined(keyCode: keyCode, down: true)
            Self.postSystemDefined(keyCode: keyCode, down: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.selfTestKeyCode = -1
            if self.interceptor.hasSeenEvent {
                self.tapVerified = true
                self.updateIcon(trusted: true)
            } else {
                self.tapVerified = false
                Log.write("[AppDelegate] tap is BLIND (stale Accessibility grant)")
                self.updateIcon(trusted: false)
                self.buildMenu()
            }
        }
    }

    /// Posts a raw system-defined (media-key) event at the HID tap.
    static func postSystemDefined(keyCode: Int32, down: Bool) {
        let data1 = (Int(keyCode) << 16) | (down ? 0x0a00 : 0x0b00)
        let ev = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: 8,
            data1: data1, data2: -1)
        ev?.cgEvent?.post(tap: .cghidEventTap)
    }

    // MARK: - Media key routing

    /// Returns true to consume, false to pass through.
    @discardableResult
    private func handleMediaKey(_ event: MediaKeyEvent) -> Bool {
        // Swallow our own health-check canary without routing it anywhere.
        if event.rawKeyCode == selfTestKeyCode {
            tapVerified = true
            return true
        }
        guard isEnabled else { return false }

        if popup.isShowing {
            popup.handleKey(event)
            return true
        }

        NowPlayingService.shared.fetchAppsFast { [weak self] apps in
            guard let self else { return }
            switch apps.count {
            case 0:
                // Nothing registered — let the system handle the key normally.
                self.reinjectKey(event)
            case 1:
                // Exactly one app — send straight to it, no picker.
                self.dispatch(event, to: apps[0].effectiveBundleID)
            default:
                // Multiple apps registered — intercept and let the user pick.
                self.popup.show(apps: apps, triggering: event)
            }
        }
        return true
    }

    /// Sends the appropriate command for a key to a specific app.
    private func dispatch(_ event: MediaKeyEvent, to bundleID: String) {
        switch event {
        case .playPause:
            NowPlayingService.shared.sendPlayPause(to: bundleID)
        case .next:
            NowPlayingService.shared.sendTrackCommand(.next, to: bundleID)
        case .previous:
            NowPlayingService.shared.sendTrackCommand(.previous, to: bundleID)
        case .other:
            break  // canary keys never route to an app
        }
    }

    /// Re-injects a media key event so the system handles it normally.
    private func reinjectKey(_ event: MediaKeyEvent) {
        let keyCode: Int
        switch event {
        case .playPause: keyCode = 16
        case .next: keyCode = 17
        case .previous: keyCode = 18
        case .other(let code): keyCode = Int(code)
        }
        func post(_ data1: Int) {
            let ev = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, subtype: 8,
                data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
        post((keyCode << 16) | 0x0000)  // key down
        post((keyCode << 16) | 0x0100)  // key up
    }

    // MARK: - Menu bar

    private func updateIcon(trusted: Bool) {
        guard let button = statusItem?.button else { return }
        let name = trusted ? "3.circle.fill" : "3.circle"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Threek") {
            img.isTemplate = true
            button.image = img
        }
        buildMenu()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(trusted: AXIsProcessTrusted())
    }

    private func buildMenu() {
        let menu = NSMenu(title: "Threek")

        if interceptor.isRunning && !tapVerified {
            let warn = NSMenuItem(
                title: "Media keys not working — re-grant Accessibility",
                action: #selector(regrantAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabled.target = self
        enabled.state = isEnabled ? .on : .off
        menu.addItem(enabled)

        menu.addItem(.separator())

        if !interceptor.isRunning {
            let ax = NSMenuItem(title: "Grant Accessibility Access…",
                                action: #selector(promptAccessibility), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Threek",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @objc private func toggleEnabled(_ item: NSMenuItem) {
        isEnabled.toggle()
        item.state = isEnabled ? .on : .off
        if !isEnabled { popup.dismiss() }
    }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        LaunchAtLogin.toggle()
        item.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        startPolling()
    }

    /// Opens System Settings at the Accessibility pane so the user can toggle
    /// Threek off and on, which revives a stale (blind) event tap. After a
    /// rebuild macOS reports the app as trusted but delivers no events until
    /// the entry is re-toggled.
    @objc private func regrantAccessibility() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        // Keep checking: once events flow again the canary will verify the tap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.verifyTapHealth()
        }
    }
}
