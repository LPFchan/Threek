import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let interceptor = MediaKeyInterceptor()
    private let popup = PopupController()
    private var refreshingWhileShowing = false
    /// Set while the first-launch window is open.
    private var onboardingWindow: OnboardingWindow?
    private var onboarding: Onboarding?
    /// What Threek had at the last check, so a grant that disappears
    /// (revoked, reset) brings the onboarding back at that step.
    private var lastGranted = Set<String>()
    /// The first onboarding step still missing a permission, from the last
    /// check (checks call into other processes, so the menu reads this).
    private var missingStep: Onboarding.Step?
    private var permissionWatch: Timer?
    /// Armed while ⏯ is held: fires pause-all unless the key comes back up
    /// first (then it's a normal press, routed on release).
    private var playPauseHold: PlayPauseHold?
    private let longPressDelay: TimeInterval = 0.5
    // Debug builds report version 1.0.0, so a running updater would find the
    // release, and with automatic installs on, swap the build out on quit.
    #if DEBUG
    private let updatesEnabled = false
    #else
    private let updatesEnabled = true
    #endif
    private lazy var updater = SPUStandardUpdaterController(
        startingUpdater: updatesEnabled, updaterDelegate: nil, userDriverDelegate: self)

    private var statusItem: NSStatusItem?
    private var isEnabled = true
    private var isPolling = false
    /// True once we've confirmed the event tap actually receives events. A
    /// stale TCC grant leaves AXIsProcessTrusted()==true but the tap blind.
    private var tapVerified = false
    private var selfTestKeyCode: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Sparkle's own schedule checks at most daily and skips the first
        // launch; also check on every launch, as Sparkle advises.
        if updatesEnabled, updater.updater.automaticallyChecksForUpdates {
            updater.updater.checkForUpdatesInBackground()
        }

        popup.onDispatch = { [weak self] app, key in
            DispatchQueue.main.async {
                self?.dispatch(key, to: app)
            }
        }

        setupMenuBar()
        // `--onboarding` shows the first-launch window again, for testing.
        // Someone who has onboarded but is missing a permission (revoked,
        // reset, a new media app) gets it back at that step.
        let firstRun = CommandLine.arguments.contains("--onboarding")
            || !UserDefaults.standard.bool(forKey: "onboarded")
        let snapshot = PermissionStatus.snapshot()
        missingStep = snapshot.missing
        lastGranted = snapshot.granted
        let unanswered = snapshot.unanswered
        let onboard = firstRun || unanswered != nil
        Log.write("[AppDelegate] launch: firstRun=\(firstRun) unanswered=\(unanswered.map { "\($0)" } ?? "none") onboard=\(onboard)")
        // The onboarding asks for each permission itself, with an
        // explanation first, rather than the bare system prompt at launch.
        checkAccessibilityAndStart(prompt: !onboard)
        if onboard { showOnboarding(from: firstRun ? .welcome : unanswered ?? .welcome) }
        watchPermissions()
        NowPlayingService.shared.warmCache()

        // `--preview-hud` auto-opens the picker shortly after launch so the
        // visual state can be verified headlessly (media-key tap may be
        // blind under a stale TCC grant).
        if CommandLine.arguments.contains("--preview-hud") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.previewHUD()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        interceptor.stop()
    }

    // MARK: - Accessibility

    private func checkAccessibilityAndStart(prompt: Bool) {
        if MediaKeyInterceptor.hasAccessibility() {
            startInterceptor()
            return
        }
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        updateIcon(trusted: false)
        startPolling()
    }

    // MARK: - Onboarding

    private func showOnboarding(from step: Onboarding.Step = .welcome) {
        if let window = onboardingWindow, let open = onboarding {
            // Already open: if a permission was just lost at an earlier
            // step, go back to it rather than letting setup finish without it.
            if step != .welcome, step.rawValue < open.step.rawValue { open.step = step }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let onboarding = Onboarding(step: step)
        self.onboarding = onboarding
        // Default the switch on only for a first-time setup; a recovery
        // (revoked permission) keeps whatever the user chose before.
        if step != .welcome { onboarding.openAtLogin = LaunchAtLogin.isEnabled }
        let window = OnboardingWindow(onboarding)
        onboarding.onFinish = { [weak self, weak onboarding] in
            guard let self, let onboarding else { return }
            // Only a finished walkthrough applies the login choice; closing
            // it early leaves login items alone.
            self.finishOnboarding(openAtLogin: onboarding.step == .done ? onboarding.openAtLogin : nil)
        }
        onboardingWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // activate() is only a request; make sure it isn't left behind.
        window.orderFrontRegardless()
    }

    private func finishOnboarding(openAtLogin: Bool?) {
        guard let window = onboardingWindow else { return }
        onboardingWindow = nil
        onboarding = nil
        UserDefaults.standard.set(true, forKey: "onboarded")
        if let openAtLogin, openAtLogin != LaunchAtLogin.isEnabled {
            LaunchAtLogin.toggle()
        }
        // The menu was built before this: Open at Login and Open Threek
        // would show the old state.
        buildMenu()
        window.close()
    }

    private func startPolling() {
        guard !isPolling else { return }
        isPolling = true
        poll()
    }

    private func poll() {
        // The check starts a process and waits for it; keep that off the
        // main thread, which also runs the event tap.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            let granted = MediaKeyInterceptor.hasAccessibility()
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.isPolling = false
                    self.startInterceptor()
                } else {
                    self.poll()
                }
            }
        }
    }

    private func startInterceptor() {
        interceptor.onKeyDown = { [weak self] event in
            self?.handleMediaKey(event) ?? false
        }
        interceptor.onKeyUp = { [weak self] event in
            self?.handleMediaKeyUp(event)
        }
        interceptor.onTapInvalidated = { [weak self] in
            self?.accessibilityLost()
        }
        interceptor.start()
        Log.write("[AppDelegate] AXIsProcessTrusted=\(AXIsProcessTrusted()) interceptor.isRunning=\(interceptor.isRunning)")
        updateIcon(trusted: interceptor.isRunning)
        guard interceptor.isRunning else { startPolling(); return }
        // The grant landed; PermissionFlow leaves its drag panel up otherwise.
        Permissions.controller.closePanel()
        // Confirm events actually arrive, every time the tap starts: a grant
        // that lands after launch (onboarding) needs checking too.
        tapVerified = false
        interceptor.resetSeenEvent()
        verifyTapHealth()
        // watchPermissions checks the grant every 2 s and takes the tap out
        // when it's gone (macOS sends nothing when it's removed).
    }

    /// The Accessibility grant is gone: take the tap out of the event path
    /// and wait for the grant to come back.
    private func accessibilityLost() {
        guard interceptor.isRunning else { return }
        interceptor.stop()
        updateIcon(trusted: false)
        Log.write("[AppDelegate] Accessibility lost; tap stopped, waiting for the grant")
        missingStep = .accessibility
        buildMenu()
        startPolling()
        showOnboarding(from: .accessibility)
    }

    /// Every few seconds, compares what Threek is granted with the last
    /// check; if anything was taken away, reopens the onboarding at the
    /// first missing step. Only a loss triggers it, so an app the user chose
    /// not to allow doesn't bring the window back again and again.
    private func watchPermissions() {
        let check = { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let snapshot = PermissionStatus.snapshot()
                let now = snapshot.granted
                let missing = snapshot.missing
                DispatchQueue.main.async {
                    guard let self else { return }
                    // This watch also covers the tap: a tap without its
                    // grant stalls input, so take it out right away.
                    if !snapshot.accessibility && self.interceptor.isRunning {
                        self.accessibilityLost()
                    }
                    let lost = self.lastGranted.subtracting(now)
                    self.lastGranted = now
                    if missing != self.missingStep {
                        self.missingStep = missing
                        self.buildMenu()
                    }
                    if !lost.isEmpty, let missing {
                        Log.write("[AppDelegate] permission revoked: \(lost.sorted())")
                        self.showOnboarding(from: missing)
                    }
                }
            }
        }
        permissionWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in check() }
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
    /// `bypassTap` marks it so our own tap lets it through untouched.
    static func postSystemDefined(keyCode: Int32, down: Bool, bypassTap: Bool = false) {
        let data1 = (Int(keyCode) << 16) | (down ? 0x0a00 : 0x0b00)
        let ev = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: 8,
            data1: data1, data2: -1)
        guard let cg = ev?.cgEvent else { return }
        if bypassTap {
            cg.setIntegerValueField(.eventSourceUserData,
                                    value: MediaKeyInterceptor.selfPostedMarker)
        }
        cg.post(tap: .cghidEventTap)
    }

    // MARK: - Media key routing

    /// Returns true to consume, false to pass through.
    @discardableResult
    private func handleMediaKey(_ event: MediaKeyEvent) -> Bool {
        // Esc only exists to dismiss the HUD; never consume it otherwise.
        if case .escape = event {
            guard popup.isInteractive else { return false }
            popup.handleKey(event)
            return true
        }

        // Swallow our own health-check canary without routing it anywhere.
        if event.rawKeyCode == selfTestKeyCode {
            tapVerified = true
            return true
        }

        // Keys Threek doesn't act on (volume, brightness, etc.) pass through
        // untouched — never query Now Playing, never pop the HUD for them.
        if case .other = event { return false }

        guard isEnabled else { return false }

        // A single-app flash doesn't take keys: the next press routes afresh
        // (and flashes again) rather than being swallowed by it.
        if popup.isInteractive {
            popup.handleKey(event)
            return true
        }

        // ⏯ acts on release so a hold can mean "pause everything" instead.
        // A fresh discovery starts right away, so a hold pauses what's
        // playing now, not what the cache last saw.
        if case .playPause = event {
            let hold = PlayPauseHold()
            playPauseHold = hold
            NowPlayingService.shared.fetchApps { [weak self] apps in
                hold.apps = apps
                if hold.fired { self?.pauseAll(apps) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay) { [weak self] in
                guard let self, self.playPauseHold === hold else { return }
                self.playPauseHold = nil
                hold.fired = true
                if let apps = hold.apps { self.pauseAll(apps) }
            }
            return true
        }

        route(event)
        return true
    }

    private func handleMediaKeyUp(_ event: MediaKeyEvent) {
        guard case .playPause = event, playPauseHold != nil else { return }
        playPauseHold = nil
        route(event)
    }

    /// Pauses every controllable app that's playing, then flashes the ones
    /// it actually reached.
    private func pauseAll(_ apps: [NowPlayingApp]) {
        let playing = apps.filter { $0.isControllable && $0.isPlaying == true }
        guard !playing.isEmpty else { return }
        NowPlayingService.shared.pauseAll(playing) { [weak self] paused in
            Log.write("[AppDelegate] pause all: " + paused.map(\.id).joined(separator: ", ")
                      + " of " + playing.map(\.id).joined(separator: ", "))
            guard !paused.isEmpty else { return }
            self?.popup.flashPauseAll(apps: paused)
        }
    }

    /// Sends a media key to the right app: straight to the only one it
    /// applies to, or through the picker when several do.
    private func route(_ event: MediaKeyEvent) {
        NowPlayingService.shared.fetchAppsFast { [weak self] apps in
            guard let self else { return }
            let controllable = apps.filter(\.isControllable)
            Log.write("[AppDelegate] route \(event): " + apps.map {
                "\($0.id)(ctl=\($0.isControllable) playing=\($0.isPlaying.map(String.init) ?? "?"))"
            }.joined(separator: ", "))
            // When exactly one controllable app is confirmed playing, send
            // the key straight to it — no picker. Metadata is fetched with
            // the client list on every refresh, so the press costs no extra
            // round-trip; an app with no rate data is treated as not playing
            // and simply falls through to the normal paths.
            let playing = controllable.filter { $0.isPlaying == true }
            if playing.count == 1 {
                self.dispatchShowing(event, to: playing[0])
                return
            }
            switch controllable.count {
            case 0:
                // Nothing we can drive — let the system handle the key
                // normally.
                if apps.isEmpty {
                    self.reinjectKey(event)
                } else {
                    // Registrants exist but none are controllable; the key
                    // is already consumed, so route it to the current
                    // now-playing app via the adapter rather than dead-key.
                    self.dispatchShowing(event, to: apps[0])
                }
            case 1:
                // Exactly one app — send straight to it, no picker.
                self.dispatchShowing(event, to: controllable[0])
            default:
                // Multiple apps registered — intercept and let the user pick.
                self.popup.show(apps: apps, triggering: event)
                self.refreshWhileShowing()
            }
        }
    }

    /// Sends a key straight to the one app it applies to, and flashes that
    /// app in the HUD so the routing is visible.
    private func dispatchShowing(_ event: MediaKeyEvent, to app: NowPlayingApp) {
        dispatch(event, to: app)
        popup.flash(app: app, key: event)
    }

    /// Sends the appropriate command for a key to a specific app.
    private func dispatch(_ event: MediaKeyEvent, to app: NowPlayingApp) {
        switch event {
        case .playPause:
            NowPlayingService.shared.sendPlayPause(to: app)
        case .next:
            NowPlayingService.shared.sendTrackCommand(.next, to: app)
        case .previous:
            NowPlayingService.shared.sendTrackCommand(.previous, to: app)
        case .escape:
            break  // dismiss-only key, never routed to an app
        case .other:
            break  // canary keys never route to an app
        }
    }

    /// Re-injects a media key event so the system handles it normally.
    private func reinjectKey(_ event: MediaKeyEvent) {
        if case .escape = event { return }  // never re-injected
        Self.postSystemDefined(keyCode: event.rawKeyCode, down: true, bypassTap: true)
        Self.postSystemDefined(keyCode: event.rawKeyCode, down: false, bypassTap: true)
    }

    // MARK: - Menu bar

    private func updateIcon(trusted: Bool) {
        guard let button = statusItem?.button else { return }
        button.image = ForkGlyph.menuBarImage(dimmed: !trusted)
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
                title: String(localized: "Media keys not working — re-grant Accessibility"),
                action: #selector(regrantAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        // Say what's missing, above everything else; Open Threek fixes it.
        if let notice = missingNotice {
            menu.addItem(NSMenuItem(title: notice, action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }

        let enabled = NSMenuItem(title: String(localized: "Enabled"), action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabled.target = self
        enabled.state = isEnabled ? .on : .off
        menu.addItem(enabled)

        #if DEBUG
        let preview = NSMenuItem(title: "Preview HUD", action: #selector(previewHUD), keyEquivalent: "p")
        preview.target = self
        menu.addItem(preview)
        #endif

        menu.addItem(.separator())

        // Setup isn't finished (a permission is missing, or the onboarding
        // was closed early): offer to pick it up where it stopped.
        if missingStep != nil || !UserDefaults.standard.bool(forKey: "onboarded") {
            let open = NSMenuItem(title: String(localized: "Open Threek"),
                                  action: #selector(openOnboarding), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }

        let artwork = NSMenuItem(title: String(localized: "Show Album Artwork"),
                                 action: #selector(toggleArtwork(_:)), keyEquivalent: "")
        artwork.target = self
        artwork.state = Preferences.showArtwork ? .on : .off
        menu.addItem(artwork)

        let login = NSMenuItem(title: String(localized: "Open at Login"), action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        let update = NSMenuItem(title: String(localized: "Check for Updates…"),
                                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                keyEquivalent: "")
        update.target = updater
        menu.addItem(update)

        let about = NSMenuItem(title: String(localized: "About Threek"),
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: String(localized: "Quit Threek"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func previewHUD() {
        NowPlayingService.shared.fetchAppsFast { [weak self] apps in
            guard let self else { return }
            // Guarantee at least 4 entries so the carousel state is exercisable
            // even when fewer players are registered right now.
            var shown = apps
            let fillers = ["com.apple.Music", "com.spotify.client", "org.videolan.vlc", "com.apple.TV"]
            for id in fillers where shown.count < 4 {
                if !shown.contains(where: { $0.effectiveBundleID == id }) {
                    shown.append(NowPlayingApp(bundleID: id, displayName: id,
                                               processIdentifier: nil, parentBundleID: nil))
                }
            }
            self.popup.show(apps: shown, triggering: .playPause)
            self.refreshWhileShowing()
        }
    }

    /// The HUD can open on a snapshot taken before a track change landed
    /// (artwork often arrives a beat after the title). Keep re-fetching while
    /// it's up and hand each result over, so late artwork still shows.
    private func refreshWhileShowing() {
        guard !refreshingWhileShowing else { return }
        refreshingWhileShowing = true
        func next() {
            NowPlayingService.shared.warmCache { [weak self] apps in
                guard let self else { return }
                guard self.popup.isShowing else {
                    self.refreshingWhileShowing = false
                    return
                }
                self.popup.update(apps: apps)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
            }
        }
        next()
    }

    @objc private func toggleEnabled(_ item: NSMenuItem) {
        isEnabled.toggle()
        item.state = isEnabled ? .on : .off
        if !isEnabled { popup.dismiss() }
    }

    @objc private func toggleArtwork(_ item: NSMenuItem) {
        Preferences.showArtwork.toggle()
        item.state = Preferences.showArtwork ? .on : .off
    }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        LaunchAtLogin.toggle()
        item.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    private var missingNotice: String? {
        switch missingStep {
        case .accessibility: return String(localized: "Accessibility is off — media keys aren’t caught")
        case .screenRecording: return String(localized: "Screen Recording is off")
        case .automation: return String(localized: "Media Control is off for some apps")
        default: return nil
        }
    }

    @objc private func openOnboarding() {
        showOnboarding(from: missingStep ?? .welcome)
    }

    /// Opens System Settings at the Accessibility pane so the user can toggle
    /// Threek off and on, which revives a stale (blind) event tap. After a
    /// rebuild macOS reports the app as trusted but delivers no events until
    /// the entry is re-toggled.
    @objc private func regrantAccessibility() {
        Permissions.openAccessibility()
        // Keep checking: once events flow again the canary will verify the tap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.verifyTapHealth()
        }
    }
}

extension AppDelegate: @preconcurrency SPUStandardUserDriverDelegate {
    // A menu bar app is never the active app, so Sparkle would leave an update
    // it found waiting behind other windows. Bring it to the front instead.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        DispatchQueue.main.async { [self] in
            NSApp.activate()
            updater.checkForUpdates(nil)
        }
    }
}

/// One press of ⏯: the discovery started on key-down, and whether the hold
/// has already passed the long-press delay.
private final class PlayPauseHold {
    var apps: [NowPlayingApp]?
    var fired = false
}
