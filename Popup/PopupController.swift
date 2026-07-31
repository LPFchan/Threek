import AppKit
import CoreGraphics
import SwiftUI

/// Physical sizing for the HUD: converts millimeters to points using the
/// display's real panel size (EDID) so the popup renders at a true physical
/// size that lines up with the built-in keyboard's function row.
enum PhysicalMetrics {
    /// The F7–F9 cluster sits right of the keyboard's centerline: F8's
    /// center is ~27mm right of it. The HUD anchors to the keys, not the
    /// screen, so its horizontal center is offset by the same amount.
    static let horizontalOffsetMM: CGFloat = 27
    /// HUD block dimensions. Fixed regardless of app count — always three
    /// icon slots visible, the selector never moves or grows. Width spans
    /// five function keys (F6→F10).
    static let hudWidthMM: CGFloat = 83.5
    static let hudHeightMM: CGFloat = 40
    /// Extra backdrop height ABOVE the content that exists purely so the
    /// blur can feather out gradually into the page — this is what makes it
    /// read as frosted glass rather than a frosted rectangle.
    static let featherHeadroomMM: CGFloat = 28
    /// Matching backdrop room BELOW the content so the bottom edge feathers
    /// out too (no hard line above the bezel).
    static let featherFootroomMM: CGFloat = 14
    /// Gap between the HUD's bottom edge and the screen's bottom edge, so
    /// the transport row clears the bezel and floats above the F-keys.
    static let bottomLiftMM: CGFloat = 6
    /// Content inset from the panel edge; the blur feathers out across this
    /// margin so the visible content sits inside the fully-blurred core.
    static let contentMarginMM: CGFloat = 10

    /// Points per physical millimeter for the screen the HUD is shown on.
    /// Falls back to 72 pt/inch (≈2.835 pt/mm) if the display doesn't
    /// report a physical size (some external monitors do this).
    static func pointsPerMM(for screen: NSScreen) -> CGFloat {
        let fallback: CGFloat = 72 / 25.4
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return fallback
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let sizeMM = CGDisplayScreenSize(displayID)
        guard sizeMM.width > 0 else { return fallback }
        let pxPerMM = CGFloat(CGDisplayPixelsWide(displayID)) / sizeMM.width
        return pxPerMM / screen.backingScaleFactor
    }

    /// HUD frame flush with the bottom edge of the screen — directly above
    /// the physical function row — horizontally centered on the F7–F9 keys
    /// rather than the screen.
    static func hudFrame(on screen: NSScreen) -> (frame: NSRect, ppm: CGFloat) {
        let ppm = pointsPerMM(for: screen)
        let size = NSSize(width: hudWidthMM * ppm,
                          height: (hudHeightMM + featherHeadroomMM + featherFootroomMM) * ppm)
        let frame = NSRect(x: screen.frame.midX + horizontalOffsetMM * ppm - size.width / 2,
                           y: screen.frame.minY + bottomLiftMM * ppm,
                           width: size.width, height: size.height)
        return (frame, ppm)
    }
}

/// Owns the floating, non-activating NSPanel that hosts the selector HUD.
@MainActor
final class PopupController {

    var isShowing: Bool { panel?.isVisible ?? false }
    var onDispatch: ((String, MediaKeyEvent) -> Void)?

    private var panel: NSPanel?
    private lazy var viewModel = SelectorViewModel()
    private var contentInset: CGFloat = 0
    private var bottomLift: CGFloat = 0

    init() {
        viewModel.onDispatch = { [weak self] bundleID, key in
            self?.dismiss()
            self?.onDispatch?(bundleID, key)
        }
        viewModel.onDismiss = { [weak self] in self?.dismiss() }
    }

    func show(apps: [NowPlayingApp], triggering: MediaKeyEvent = .playPause) {
        if let screen = NSScreen.main {
            let (frame, ppm) = PhysicalMetrics.hudFrame(on: screen)
            contentInset = PhysicalMetrics.contentMarginMM * ppm
            bottomLift = PhysicalMetrics.featherFootroomMM * ppm
            if panel == nil { buildPanel() }
            panel?.setFrame(frame, display: false)
        }
        viewModel.present(apps: apps, triggering: triggering)
        guard let panel else { return }
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
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false

        // A plain container we fully control. Its CALayer mask feathers the
        // LIVE vibrancy blur (a sibling under the SwiftUI content) out to
        // transparent at every edge. Masking the container — not the effect
        // view's private sublayers — is what makes the feather actually apply.
        let container = FeatheredContainerView()
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blur)

        let content = NSHostingView(rootView: SelectorPopup(viewModel: viewModel,
                                                            contentInset: contentInset,
                                                            bottomLift: bottomLift))
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        p.contentView = container
        panel = p
    }
}

/// An NSView whose CALayer mask is a two-axis smoothstep feather, so the
/// vibrancy blur inside dissolves to fully transparent at all four edges
/// with no hard boundary. Regenerates the mask whenever its bounds change.
private final class FeatheredContainerView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        layer?.mask = Self.makeFeatherMask(bounds: bounds,
                                           featherX: 0.30, featherY: 0.32)
    }

    /// Renders a grayscale ramp bitmap used as the layer's alpha mask:
    /// opaque core, smoothstep fade on every edge.
    private static func makeFeatherMask(bounds: CGRect,
                                        featherX: CGFloat, featherY: CGFloat) -> CALayer {
        let scale: CGFloat = 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        var pixels = [UInt8](repeating: 0, count: w * h)
        let fx = max(1, Int(CGFloat(w) * featherX))
        let fy = max(1, Int(CGFloat(h) * featherY))
        func ramp(_ i: Int, _ edge: Int, _ max: Int) -> Double {
            let d = min(i, max - 1 - i) // distance to nearest edge
            if d >= edge { return 1 }
            let t = Double(d) / Double(edge)
            return t * t * (3 - 2 * t) // smoothstep
        }
        for y in 0..<h {
            let ay = ramp(y, fy, h)
            for x in 0..<w {
                pixels[y * w + x] = UInt8(min(ay, ramp(x, fx, w)) * 255)
            }
        }
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: 0),
              let cgImage = ctx.makeImage()
        else { return CALayer() }
        let mask = CALayer()
        mask.frame = bounds
        mask.contents = cgImage
        return mask
    }
}

private struct SelectorPopup: View {
    @ObservedObject var viewModel: SelectorViewModel
    var contentInset: CGFloat = 0
    var bottomLift: CGFloat = 0

    var body: some View {
        VStack(spacing: 10) {
            iconRow
            transportRow
        }
        .padding(.horizontal, contentInset)
        .padding(.top, contentInset)
        // Lift content off the panel's bottom edge by the footroom so the
        // blur has room to feather out below, mirroring the headroom above.
        .padding(.bottom, contentInset + bottomLift)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Which icon index each transport key maps to, for the direct-mapping
    /// (2–3 app) states. Returns nil in the 4+ selection state.
    private var keyMap: (previous: Int?, playPause: Int?, next: Int?) {
        switch viewModel.state {
        case .showing(let apps):
            if apps.count == 2 { return (0, nil, 1) }
            return (0, 1, 2)
        default:
            return (nil, nil, nil)
        }
    }

    @ViewBuilder
    private var iconRow: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .showing(let apps):
            HStack(spacing: 10) {
                ForEach(apps) { app in AppIconView(app: app) }
            }
        case .selecting:
            // Carousel: the selected app always occupies the center slot
            // under the stationary ring; neighbors wrap around.
            let selected = viewModel.state.selectedIndex ?? 0
            HStack(spacing: 10) {
                ForEach(Array(viewModel.state.windowedApps.enumerated()),
                        id: \.element.id) { slot, app in
                    AppIconView(app: app, isSelected: slot == 1)
                }
            }
            .animation(.easeOut(duration: 0.12), value: selected)
        }
    }

    /// ← ⏸ → hints aligned under the icons their keys would trigger.
    @ViewBuilder
    private var transportRow: some View {
        let map = keyMap
        HStack(spacing: 22) {
            TransportGlyph(systemName: "arrow.left",
                           active: map.previous != nil)
            TransportGlyph(systemName: viewModel.state.isSelecting ? "playpause" : "pause",
                           active: viewModel.state.isSelecting || map.playPause != nil)
            TransportGlyph(systemName: "arrow.right",
                           active: map.next != nil)
        }
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(.white)
    }
}

private struct AppIconView: View {
    let app: NowPlayingApp
    var isSelected: Bool = false

    var body: some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white, lineWidth: 2.5)
                    .frame(width: 84, height: 84)
            }
            if let icon = app.icon {
                Image(nsImage: icon).resizable()
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
            } else {
                Image(systemName: "app.fill").resizable()
                    .frame(width: 68, height: 68)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 84, height: 84)
        .opacity(app.isControllable ? 1 : 0.35)
        .saturation(app.isControllable ? 1 : 0)
        .opacity(app.isControllable ? 1 : 0.6)
        .help(app.isControllable ? app.displayName
              : "\(app.displayName) — can't be controlled right now")
    }
}

private struct TransportGlyph: View {
    let systemName: String
    let active: Bool

    var body: some View {
        Image(systemName: systemName)
            .frame(width: 84, height: 34)
            .opacity(active ? 0.95 : 0.2)
    }
}

/// Pure-SwiftUI feather mask: opaque core, smoothstep fade on all four
/// edges, built from standard primitives so it blends correctly in a
