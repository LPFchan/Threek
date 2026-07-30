import AppKit
import SwiftUI

/// Owns the floating, non-activating NSPanel that hosts the selector HUD.
@MainActor
final class PopupController {

    var isShowing: Bool { panel?.isVisible ?? false }
    var onDispatch: ((String, MediaKeyEvent) -> Void)?

    private var panel: NSPanel?
    private lazy var viewModel = SelectorViewModel()

    init() {
        viewModel.onDispatch = { [weak self] bundleID, key in
            self?.dismiss()
            self?.onDispatch?(bundleID, key)
        }
        viewModel.onDismiss = { [weak self] in self?.dismiss() }
    }

    func show(apps: [NowPlayingApp], triggering: MediaKeyEvent = .playPause) {
        if panel == nil { buildPanel() }
        viewModel.present(apps: apps, triggering: triggering)
        guard let panel else { return }
        if let screen = NSScreen.main {
            let size = NSSize(width: 340, height: 150)
            let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                                 y: screen.frame.midY - size.height / 2)
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    func handleKey(_ event: MediaKeyEvent) {
        viewModel.handleKey(event)
    }

    private func buildPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: SelectorPopup(viewModel: viewModel))
        panel = p
    }
}

private struct SelectorPopup: View {
    @ObservedObject var viewModel: SelectorViewModel

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            content.padding(20)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .showing(let apps):
            HStack(spacing: 24) {
                ForEach(apps) { app in AppIconView(app: app) }
            }
        case .selecting(let apps, let index):
            HStack(spacing: 16) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                    AppIconView(app: app, isSelected: i == index)
                }
            }
        }
    }
}

private struct AppIconView: View {
    let app: NowPlayingApp
    var isSelected: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.accentColor, lineWidth: 2.5)
                        .frame(width: 76, height: 76)
                }
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(systemName: "app.fill").resizable()
                        .frame(width: 64, height: 64)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)
            Text(app.displayName).font(.caption).lineLimit(1)
        }
    }
}

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
