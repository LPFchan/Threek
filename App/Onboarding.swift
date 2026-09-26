import AppKit
import SwiftUI

/// First-launch wizard: what Threek does, every permission it needs (one
/// step each, all up front), and where to find it afterwards. Reopened at
/// the first missing step when a permission is revoked.
@Observable
final class Onboarding {
    enum Step: Int, CaseIterable { case welcome, accessibility, screenRecording, automation, done }

    var step: Step
    var trusted = MediaKeyInterceptor.hasAccessibility()
    var screenGranted = PermissionStatus.screenRecording
    /// Automation answer per installed player.
    var automation: [String: PermissionStatus.Automation] = [:]
    var asking = false
    var openAtLogin = true
    @ObservationIgnored var onFinish: () -> Void = {}

    init(step: Step = .welcome) { self.step = step }

    var players: [String] { PermissionStatus.installedPlayers }
    var automationDone: Bool { players.allSatisfy { automation[$0] == .allowed } }
    var automationUnasked: Bool {
        players.contains { automation[$0] == nil || automation[$0] == .notAsked || automation[$0] == .notRunning }
    }

    /// Re-reads the answers macOS has for running players; one that isn't
    /// running keeps what was last learned about it.
    @MainActor func refreshAutomation() async {
        for id in players {
            let state = await Task.detached { PermissionStatus.automation(id, ask: false) }.value
            if state != .notRunning || automation[id] == nil { automation[id] = state }
        }
    }

    /// Asks macOS for every player not yet answered. One that isn't running
    /// is opened hidden just long enough to ask (macOS can only ask about a
    /// running app), then quit again.
    @MainActor func askAutomation() async {
        asking = true
        defer { asking = false }
        for id in players where automation[id] != .allowed && automation[id] != .denied {
            var launched: NSRunningApplication?
            if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.hides = true
                config.addsToRecentItems = false
                launched = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                for _ in 0..<40 where launched?.isFinishedLaunching == false {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                // Finished launching isn't quite ready for Apple events.
                try? await Task.sleep(for: .seconds(1))
            }
            automation[id] = await Task.detached { PermissionStatus.automation(id, ask: true) }.value
            launched?.terminate()
        }
    }
}

final class OnboardingWindow: NSWindow, NSWindowDelegate {
    private let onboarding: Onboarding

    init(_ onboarding: Onboarding) {
        self.onboarding = onboarding
        super.init(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        delegate = self
        contentView = NSHostingView(rootView: OnboardingView(onboarding: onboarding))
        center()
    }

    // Closing it early counts as done: it won't show again until a
    // permission is revoked, and the menu bar still offers the grant.
    func windowWillClose(_ notification: Notification) { onboarding.onFinish() }
}

/// The app icon's darker and lighter greys.
private let accent = Color(red: 0x6A / 255, green: 0x6C / 255, blue: 0x74 / 255)
private let accentLight = Color(red: 0xA4 / 255, green: 0xA6 / 255, blue: 0xAD / 255)

private struct OnboardingView: View {
    @Bindable var onboarding: Onboarding

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch onboarding.step {
                case .welcome: WelcomeStep()
                case .accessibility: AccessibilityStep(onboarding: onboarding)
                case .screenRecording: ScreenRecordingStep(onboarding: onboarding)
                case .automation: AutomationStep(onboarding: onboarding)
                case .done: DoneStep(openAtLogin: $onboarding.openAtLogin)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 52)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(onboarding.step)

            primaryButton
            HStack(spacing: 8) {
                ForEach(Onboarding.Step.allCases, id: \.self) { step in
                    Circle().fill(step == onboarding.step ? accent : .secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 26)
        }
        .frame(width: 640, height: 600)
        .background {
            LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.04)], startPoint: .top, endPoint: .bottom)
                .background(.background)
                .ignoresSafeArea()
        }
        .animation(.spring(duration: 0.45), value: onboarding.step)
        // Granting happens in System Settings; move on when it lands.
        .onChange(of: onboarding.trusted) { _, trusted in
            guard trusted, onboarding.step == .accessibility else { return }
            Permissions.controller.closePanel()
            NSApp.activate()
            next()
        }
        .onChange(of: onboarding.screenGranted) { _, granted in
            guard granted, onboarding.step == .screenRecording else { return }
            Permissions.controller.closePanel()
            NSApp.activate()
            next()
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch onboarding.step {
        case .welcome:
            PrimaryButton("Get Started") { next() }
        case .accessibility:
            if onboarding.trusted {
                PrimaryButton("Continue") { next() }
            } else {
                PrimaryButton("Allow Accessibility Access") { Permissions.openAccessibility() }
            }
        case .screenRecording:
            if onboarding.screenGranted {
                PrimaryButton("Continue") { next() }
            } else {
                PrimaryButton("Allow Screen Recording") { Permissions.openScreenRecording() }
            }
        case .automation:
            if onboarding.asking {
                PrimaryButton("Asking…") {}.disabled(true)
            } else if onboarding.automationDone {
                PrimaryButton("Continue") { next() }
            } else if onboarding.automationUnasked {
                PrimaryButton("Allow Media Control") { Task { await onboarding.askAutomation() } }
            } else {
                PrimaryButton("Open System Settings") { Permissions.openAutomation() }
            }
        case .done:
            PrimaryButton("Done") { onboarding.onFinish() }
        }
    }

    private func next() {
        onboarding.step = Onboarding.Step(rawValue: onboarding.step.rawValue + 1) ?? .done
    }


}

private struct PrimaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    init(_ title: LocalizedStringKey, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 16)
                .frame(width: 300, height: 48)
                .background(accent.opacity(enabled ? 1 : 0.45), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}

private struct Header: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 26) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Header(title: "Welcome to Threek",
                   subtitle: "Choose which app your media keys control, right from the keyboard.")
            VStack(spacing: 14) {
                HUDDemo()
                Note("When more than one app is playing, ⏯ shows each one over the F-key that picks it.")
            }
        }
    }
}

/// The real HUD, opening over three made-up covers and picking F7, F8 and
/// F9 in turn.
private struct HUDDemo: View {
    @StateObject private var model = SelectorViewModel()
    private static let scale: CGFloat = 0.6

    var body: some View {
        let s = Self.scale
        SelectorPopup(viewModel: model)
            .frame(width: (PhysicalMetrics.designContentWidth + PhysicalMetrics.designMargin * 2) * s,
                   height: (PhysicalMetrics.designContentHeight + PhysicalMetrics.designMargin * 2) * s)
            .padding(.horizontal, 60)
            .background(Color(white: 0.08), in: .rect(cornerRadius: 16))
            .environment(\.colorScheme, .dark)
            .task { await loop() }
    }

    @MainActor private func loop() async {
        model.scale = Self.scale
        let apps = Self.apps
        let keys: [MediaKeyEvent] = [.previous, .playPause, .next]
        for i in 0... {
            model.present(apps: apps)
            try? await Task.sleep(for: .seconds(1.6))
            model.handleKey(keys[i % keys.count])
            try? await Task.sleep(for: .seconds(0.9))
            model.disappear()
            try? await Task.sleep(for: .seconds(0.6))
            if Task.isCancelled { return }
        }
    }

    /// Built-in apps, so their icons exist on every Mac, with plain gradient
    /// covers standing in for album art.
    private static let apps: [NowPlayingApp] = [
        ("com.apple.Music", NSColor(red: 0.85, green: 0.16, blue: 0.14, alpha: 1), NSColor(red: 0.25, green: 0.03, blue: 0.05, alpha: 1)),
        ("com.apple.podcasts", NSColor(red: 0.96, green: 0.72, blue: 0.45, alpha: 1), NSColor(red: 0.55, green: 0.30, blue: 0.62, alpha: 1)),
        ("com.apple.QuickTimePlayerX", NSColor(red: 0.62, green: 0.60, blue: 1.00, alpha: 1), NSColor(red: 0.98, green: 0.78, blue: 0.90, alpha: 1)),
    ].map { id, top, bottom in
        var app = NowPlayingApp(bundleID: id, displayName: id, processIdentifier: nil, parentBundleID: nil)
        app.artwork = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -60)
            return true
        }
        return app
    }
}

private struct Note: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
    }
}

private struct AccessibilityStep: View {
    let onboarding: Onboarding

    var body: some View {
        VStack(spacing: 26) {
            Symbol("keyboard.fill")
            Header(title: "Let Threek catch your media keys",
                   subtitle: "Threek needs Accessibility access to catch ⏯, ⏮ and ⏭ before macOS sends them to an app. It ignores every other key.")
            Group {
                if onboarding.trusted {
                    Label("Accessibility access allowed", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                } else {
                    Text("Turn on Threek in the list, then come back here.").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        // macOS posts nothing when the grant changes, so check while here.
        .task {
            while !Task.isCancelled && !onboarding.trusted {
                try? await Task.sleep(for: .seconds(0.5))
                onboarding.trusted = MediaKeyInterceptor.hasAccessibility()
            }
        }
    }
}

private struct ScreenRecordingStep: View {
    let onboarding: Onboarding

    var body: some View {
        VStack(spacing: 26) {
            Symbol("rectangle.dashed.badge.record")
            Header(title: "Let Threek see behind the HUD",
                   subtitle: "Threek looks at the part of the screen behind its HUD to pick white or black text you can read. Nothing is recorded or saved.")
            Group {
                if onboarding.screenGranted {
                    Label("Screen Recording allowed", systemImage: "checkmark.circle.fill").foregroundStyle(accent)
                } else {
                    Text("Turn on Threek in the list. If macOS asks to quit and reopen Threek, go ahead; setup picks up where it left off.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }
        .task {
            while !Task.isCancelled && !onboarding.screenGranted {
                try? await Task.sleep(for: .seconds(0.5))
                onboarding.screenGranted = PermissionStatus.screenRecording
            }
        }
    }
}

private struct AutomationStep: View {
    let onboarding: Onboarding

    var body: some View {
        VStack(spacing: 26) {
            Symbol("play.rectangle.on.rectangle.fill")
            Header(title: "Let Threek control your media apps",
                   subtitle: "Threek sends play and pause to the app you pick. macOS asks once for each app; Threek opens any that aren't running in the background just long enough to ask.")
            if onboarding.players.isEmpty {
                Note("No supported media apps found. macOS will ask when Threek first controls one.")
            } else {
                HStack(spacing: 18) {
                    ForEach(onboarding.players, id: \.self) { id in
                        PlayerStatus(bundleID: id, state: onboarding.automation[id])
                    }
                }
                if !onboarding.asking && !onboarding.automationDone && !onboarding.automationUnasked {
                    Note("Turn on the apps you want Threek to control under Automation, then come back here.")
                    Button("Continue") { onboarding.step = .done }
                        .buttonStyle(.link)
                }
            }
        }
        // Answers change in System Settings too; keep them current here.
        .task {
            while !Task.isCancelled {
                if !onboarding.asking { await onboarding.refreshAutomation() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct PlayerStatus: View {
    let bundleID: String
    let state: PermissionStatus.Automation?

    var body: some View {
        VStack(spacing: 6) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
            }
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state == .allowed ? accent : .secondary)
        }
    }

    private var symbol: String {
        switch state {
        case .allowed: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        default: return "circle.dashed"
        }
    }
}

private struct DoneStep: View {
    @Binding var openAtLogin: Bool

    var body: some View {
        VStack(spacing: 26) {
            Symbol("checkmark.seal.fill")
            Header(title: "You’re all set",
                   subtitle: "Press ⏯ when more than one app is playing, then pick one with F7, F8 or F9. Hold ⏯ to pause everything.")
            HStack(spacing: 10) {
                Image(nsImage: ForkGlyph.menuBarImage(dimmed: false))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.secondary.opacity(0.15), in: .rect(cornerRadius: 6))
                Text("Threek lives in the menu bar. Click it to turn Threek off or change its settings.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 440)
            Toggle("Open Threek when I log in", isOn: $openAtLogin)
                .toggleStyle(.switch)
                .tint(accentLight)
                .font(.system(size: 14, weight: .medium))
        }
    }
}

private struct Symbol: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 44, weight: .medium))
            .foregroundStyle(accent)
            .frame(width: 84, height: 84)
    }
}
