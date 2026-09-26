import AppKit
import SwiftUI

/// First-launch wizard: what Threek does, the Accessibility permission, and
/// where to find it afterwards.
@Observable
final class Onboarding {
    enum Step: Int, CaseIterable { case welcome, permission, done }

    var step = Step.welcome
    var trusted = AXIsProcessTrusted()
    var openAtLogin = true
    /// The system Accessibility prompt only shows once; after that the
    /// button opens System Settings instead.
    @ObservationIgnored var prompted = false
    @ObservationIgnored var onFinish: () -> Void = {}
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

    // Closing it early counts as done: it won't show again, and the menu bar
    // still offers the Accessibility grant.
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
                case .permission: PermissionStep(onboarding: onboarding)
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
            guard trusted, onboarding.step == .permission else { return }
            NSApp.activate()
            next()
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch onboarding.step {
        case .welcome:
            PrimaryButton("Get Started") { next() }
        case .permission:
            if onboarding.trusted {
                PrimaryButton("Continue") { next() }
            } else {
                PrimaryButton("Allow Accessibility Access") { requestAccess() }
            }
        case .done:
            PrimaryButton("Done") { onboarding.onFinish() }
        }
    }

    private func next() {
        onboarding.step = Onboarding.Step(rawValue: onboarding.step.rawValue + 1) ?? .done
    }

    private func requestAccess() {
        if onboarding.prompted {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else {
            onboarding.prompted = true
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
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

private struct PermissionStep: View {
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
            Note("The first time Threek controls an app, macOS will ask you to allow that too.")
        }
        // macOS posts nothing when the grant changes, so check while here.
        .task {
            while !Task.isCancelled && !onboarding.trusted {
                try? await Task.sleep(for: .seconds(0.5))
                onboarding.trusted = AXIsProcessTrusted()
            }
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
