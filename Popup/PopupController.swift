import AppKit
import CoreGraphics
import Metal
import ScreenCaptureKit
import SwiftUI

/// GPU-backed CIContext shared by the content shadow and the luminance
/// sampling, so both are hardware-accelerated via Metal. Falls back to a
/// default context if no Metal device is available.
private enum SharedGPUContext {
    static let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device,
                             options: [.cacheIntermediates: false])
        }
        return CIContext()
    }()
}

/// A MacBook keyboard's function-row geometry, measured off Apple's keycap
/// maps (support.apple.com/101269). Each map was scaled by its letter-key
/// pitch: both families' keyboards span exactly 14.36 pitches, and the 31 mm
/// Caps Lock keycap puts that pitch at 19.35 mm.
struct KeyboardLayout {
    /// Width of one function keycap.
    let keycapMM: CGFloat
    /// Center-to-center distance between neighboring function keys.
    let keyPitchMM: CGFloat
    /// F8's center, right of the keyboard's centerline; nil when there are
    /// no physical F-keys (Touch Bar), so the HUD centers on the screen.
    let f8OffsetMM: CGFloat?

    /// MacBook Air (M2, 2022) and later, MacBook Pro 14/16 (2021) and later:
    /// full-height F-keys between a 1.5-wide Esc and a 1-wide Touch ID.
    static let fullHeight = KeyboardLayout(keycapMM: 16.7, keyPitchMM: 19.35, f8OffsetMM: 33.8)
    /// MacBook Air (Retina, 2020) and (M1, 2020): half-height F-keys, Esc as
    /// wide as an F-key, and a narrow Touch ID.
    static let halfHeight = KeyboardLayout(keycapMM: 17.9, keyPitchMM: 20.6, f8OffsetMM: 35.4)
    /// Touch Bar MacBook Pros: no F-keys; size like the letter keys.
    static let touchBar = KeyboardLayout(keycapMM: 16.7, keyPitchMM: 19.35, f8OffsetMM: nil)

    /// This Mac's layout, from its model identifier. Anything not listed is
    /// assumed to be a current (full-height) keyboard.
    static let current: KeyboardLayout = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return layout(forModel: String(cString: bytes))
    }()

    static func layout(forModel model: String) -> KeyboardLayout {
        if ["MacBookAir9,1", "MacBookAir10,1"].contains(model) { return .halfHeight }
        // MacBookPro15–17: every 2018–2020 MacBook Pro has a Touch Bar;
        // Mac14,7 is the 13-inch M2.
        if model == "Mac14,7" || ["MacBookPro15,", "MacBookPro16,", "MacBookPro17,"]
            .contains(where: model.hasPrefix) { return .touchBar }
        return .fullHeight
    }
}

/// Physical sizing for the HUD. On a MacBook's built-in display the HUD is
/// drawn at true physical size: each icon is exactly as wide as a function
/// keycap, icons sit one key pitch apart, and the middle one is centered over
/// F8, whatever the display's resolution or scaling setting. The keyboard and
/// the display are both centered on the chassis, so keyboard center = screen
/// center.
enum PhysicalMetrics {
    static let layout = KeyboardLayout.current
    /// Gap between the screen's bottom edge and the panel's bottom edge.
    static let bottomLiftMM: CGFloat = 4

    /// The SwiftUI views are laid out in design units where one keycap is
    /// 84 wide; `scale(for:)` maps those units to points.
    static let designKeycap: CGFloat = 84
    /// Gap between icons, in design units: pitch minus keycap.
    static let designGap: CGFloat = designKeycap * (layout.keyPitchMM / layout.keycapMM - 1)
    /// Empty margin around the content, in design units, so the drop
    /// shadow fades out before the panel edge.
    static let designMargin: CGFloat = 28
    /// Content size in design units: three slots plus the carousel's
    /// neighbor overhang; icon + spacing + badge/transport row.
    static let designContentWidth: CGFloat = designKeycap * 3 + designGap * 2 + 44
    static let designContentHeight: CGFloat = designKeycap + 10 + 34

    /// Points per millimeter of the built-in display, or nil for any other
    /// display. Uses the screen's width in points (which already includes the
    /// "scaled" resolution) over the panel's physical width, so it holds at
    /// every scaling setting.
    static func pointsPerMM(for screen: NSScreen) -> CGFloat? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard CGDisplayIsBuiltin(displayID) != 0 else { return nil }
        let sizeMM = CGDisplayScreenSize(displayID)
        guard sizeMM.width > 0 else { return nil }
        return screen.frame.width / sizeMM.width
    }

    /// The screen above the keys being pressed: the built-in display when
    /// it's on, otherwise the main screen.
    static var hudScreen: NSScreen? {
        NSScreen.screens.first { pointsPerMM(for: $0) != nil } ?? NSScreen.main
    }

    /// Points per design unit. On other displays there are no keys to line
    /// up with, so one design unit is one point.
    static func scale(for screen: NSScreen) -> CGFloat {
        guard let ppm = pointsPerMM(for: screen) else { return 1 }
        return layout.keycapMM * ppm / designKeycap
    }

    /// Panel frame: centered over F8 on the built-in display (screen center
    /// on other displays and Touch Bar Macs), just above the bottom edge.
    static func hudFrame(on screen: NSScreen) -> (frame: NSRect, scale: CGFloat) {
        let s = scale(for: screen)
        let ppm = pointsPerMM(for: screen)
        let size = NSSize(width: (designContentWidth + designMargin * 2) * s,
                          height: (designContentHeight + designMargin * 2) * s)
        var offset: CGFloat = 0
        if let ppm, let f8 = layout.f8OffsetMM { offset = f8 * ppm }
        let centerX = screen.frame.midX + offset
        let lift = (ppm ?? designKeycap / layout.keycapMM) * bottomLiftMM
        let frame = NSRect(x: centerX - size.width / 2, y: screen.frame.minY + lift,
                           width: size.width, height: size.height)
        return (frame, s)
    }
}

/// Points per design unit for the HUD's SwiftUI views (see PhysicalMetrics).
private struct HUDScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private extension EnvironmentValues {
    var hudScale: CGFloat {
        get { self[HUDScaleKey.self] }
        set { self[HUDScaleKey.self] = newValue }
    }
}

/// Owns the floating, non-activating NSPanel that hosts the selector HUD.
@MainActor
final class PopupController {

    var isShowing: Bool { panel?.isVisible ?? false }
    var onDispatch: ((String, MediaKeyEvent) -> Void)?

    private var panel: NSPanel?
    private lazy var viewModel = SelectorViewModel()
    private var shadowLayer: ShadowCastingView?
    private weak var contentView: NSView?

    init() {
        viewModel.onDispatch = { [weak self] bundleID, key in
            self?.dismiss()
            self?.onDispatch?(bundleID, key)
        }
        viewModel.onDismiss = { [weak self] in self?.dismiss() }
    }

    func show(apps: [NowPlayingApp], triggering: MediaKeyEvent = .playPause) {
        if let screen = PhysicalMetrics.hudScreen {
            let (frame, scale) = PhysicalMetrics.hudFrame(on: screen)
            viewModel.scale = scale
            if panel == nil { buildPanel(size: frame.size) }
            shadowLayer?.blurRadius = 7 * scale
            shadowLayer?.offsetY = 2 * scale
            panel?.setFrame(frame, display: false)
            // Sample what's actually behind the panel BEFORE it orders
            // front, so the glyphs adapt to the real background, not the
            // HUD itself.
            updateGlyphColor(for: frame, on: screen)
        }
        viewModel.present(apps: apps, triggering: triggering)
        guard let panel else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        // Sample the content's silhouettes for the shadow once SwiftUI has
        // laid out the new icon set. Deferred so the hosting view has pixels.
        DispatchQueue.main.async { [weak self] in
            guard let self, let content = self.contentView else { return }
            self.shadowLayer?.update(from: content)
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

    private func buildPanel(size: NSSize) {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false

        // The container is a fixed size (matching the panel) and its subviews
        // use explicit frames, so the hosting view never resizes the panel —
        // the panel owns its frame. No backdrop: the HUD is chrome-less, its
        // content separated from the desktop purely by the shadow below.
        let container = NSView()

        // A dedicated shadow layer under the SwiftUI content. It renders the
        // content's silhouettes (icons + glyphs) as a soft, blurred black
        // shadow, so the content lifts off whatever is behind the HUD. It
        // samples the content view's pixels each time the HUD is shown.
        let shadow = ShadowCastingView()
        container.addSubview(shadow)

        let content = NSHostingView(rootView: SelectorPopup(viewModel: viewModel))
        container.addSubview(content)

        container.frame = NSRect(origin: .zero, size: size)
        shadow.frame = NSRect(origin: .zero, size: size)
        shadow.autoresizingMask = [.width, .height]
        content.frame = NSRect(origin: .zero, size: size)
        content.autoresizingMask = [.width, .height]

        self.shadowLayer = shadow
        self.contentView = content

        p.contentView = container
        panel = p
    }

    /// Samples the screen region the HUD is about to cover and sets the
    /// glyphs' light/dark appearance from its average luminance. Uses a
    /// one-shot SCScreenshotManager capture taken before the panel orders
    /// front, so the HUD itself never pollutes the sample; no persistent
    /// stream, and the one-shot API needs no Screen Recording permission.
    private func updateGlyphColor(for frame: NSRect, on screen: NSScreen) {
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        // SCStreamConfiguration/sourceRect work in points with a top-left
        // origin; AppKit frames are points, bottom-left — flip Y only.
        let rect = CGRect(x: frame.minX,
                          y: primaryH - frame.maxY,
                          width: frame.width,
                          height: frame.height)
        let scale = screen.backingScaleFactor
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let excludeID = panel.map { CGWindowID($0.windowNumber) }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true),
                let display = content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.first else { return }
            let excluded = content.windows.filter { $0.windowID == excludeID }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = max(1, Int(rect.width * scale))
            config.height = max(1, Int(rect.height * scale))
            config.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config) else { return }
            let lum = Self.averageLuminance(of: image)
            await MainActor.run { [weak self] in
                self?.viewModel.backdropLuminance = lum
            }
        }
    }

    /// Reduces an image to a single average luminance (0–1): monochrome it,
    /// then area-average the whole frame down to one value.
    private static func averageLuminance(of image: CGImage) -> CGFloat {
        let ci = CIImage(cgImage: image)
        let extent = ci.extent
        guard extent.width > 0, extent.height > 0 else { return 0 }
        // Monochrome: drop saturation to zero so color can't skew the read.
        guard let mono = CIFilter(name: "CIColorControls"),
              let avg = CIFilter(name: "CIAreaAverage") else { return 0 }
        mono.setValue(ci, forKey: kCIInputImageKey)
        mono.setValue(0.0, forKey: kCIInputSaturationKey)
        avg.setValue(mono.outputImage, forKey: kCIInputImageKey)
        avg.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        guard let out = avg.outputImage else { return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        SharedGPUContext.context.render(out,
                                        toBitmap: &pixel,
                                        rowBytes: 4,
                                        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                        format: .RGBA8,
                                        colorSpace: CGColorSpaceCreateDeviceRGB())
        // Rec. 709 luma from the averaged RGB.
        let r = CGFloat(pixel[0]) / 255, g = CGFloat(pixel[1]) / 255, b = CGFloat(pixel[2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

/// Renders the content's silhouettes as a single soft drop shadow. Lives as
/// a subview directly under the content, so the icons and glyphs read as
/// floating just above the desktop.
///
/// It snapshots the content view, keeps only the alpha of each pixel (the
/// silhouette), fills that shape black, and blurs it — a classic
/// shadow-from-content technique. The blur softens it; the opacity and
/// offset below set the shadow's weight and drop.
private final class ShadowCastingView: NSView {
    /// Gaussian blur radius of the shadow, in points — the softness.
    var blurRadius: CGFloat = 7
    /// Shadow opacity.
    var opacity: CGFloat = 0.5
    /// Downward offset of the shadow, in points.
    var offsetY: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resize
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the shadow from the content view's current pixels.
    func update(from content: NSView) {
        guard bounds.width > 0, bounds.height > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let cg = rep.cgImage else { return }

        let ci = CIImage(cgImage: cg)
        let extent = ci.extent
        // 1) Black shape keyed to the content's alpha (its silhouette).
        // 2) Blur it. 3) Drop opacity. 4) Nudge down.
        guard let color = CIFilter(name: "CIColorMatrix"),
              let blur = CIFilter(name: "CIGaussianBlur") else { return }
        color.setValue(ci, forKey: kCIInputImageKey)
        color.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        color.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        color.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        color.setValue(CIVector(x: 0, y: 0, z: 0, w: opacity), forKey: "inputAVector")
        blur.setValue(color.outputImage, forKey: kCIInputImageKey)
        blur.setValue(blurRadius, forKey: kCIInputRadiusKey)
        let shifted = blur.outputImage?
            .transformed(by: CGAffineTransform(translationX: 0, y: offsetY))
            .cropped(to: extent)
        guard let out = shifted,
              let rendered = SharedGPUContext.context.createCGImage(out, from: extent)
        else { return }
        layer?.contents = rendered
    }
}

private struct SelectorPopup: View {
    @ObservedObject var viewModel: SelectorViewModel

    var body: some View {
        let s = viewModel.scale
        VStack(spacing: 10 * s) {
            iconRow
            keyRow
        }
        .padding(PhysicalMetrics.designMargin * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.hudScale, s)
    }

    @ViewBuilder
    private var iconRow: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .showing(let apps):
            // One icon per function key, badge aligned directly under it.
            // Icons sit one key pitch apart; with two apps they skip F8's
            // slot so each lands over the key it names (F7, F9).
            let s = viewModel.scale
            let gap = PhysicalMetrics.designGap
            HStack(spacing: (apps.count == 2 ? gap * 2 + PhysicalMetrics.designKeycap : gap) * s) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    VStack(spacing: 10 * s) {
                        AppIconView(app: app)
                        KeyBadge(label: keyLabel(for: index),
                                 inverted: glyphInverted)
                    }
                }
            }
        case .selecting:
            CarouselRow(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var keyRow: some View {
        switch viewModel.state {
        case .showing:
            // The badges live in the icon columns above (2–3 app layout).
            EmptyView()
        case .selecting:
            TransportRow(viewModel: viewModel, inverted: glyphInverted)
        case .idle:
            EmptyView()
        }
    }

    /// Function-key label for the app at `index` in the 2–3 app direct
    /// mapping. F7 is the first slot; F8 is skipped entirely with two apps
    /// because ⏯ is unreachable there (it dispatches to slot one).
    private func keyLabel(for index: Int) -> String {
        let number = 7 + index + (viewModel.state.apps.count == 2 && index > 0 ? 1 : 0)
        return "F\(number)"
    }

    /// True when the screen behind the HUD is light enough that on-HUD text
    /// should read dark instead of white.
    private var glyphInverted: Bool {
        viewModel.backdropLuminance > 0.5
    }
}

private struct AppIconView: View {
    let app: NowPlayingApp
    var isSelected: Bool = false
    @Environment(\.hudScale) private var s

    var body: some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 20 * s)
                    .stroke(Color.white, lineWidth: 2.5 * s)
                    .frame(width: 84 * s, height: 84 * s)
            }
            if let artwork = app.artwork {
                // Album artwork leads, with the app icon badged in the corner —
                // the reference mockup's pairing. Falls back to the plain icon
                // below when the app publishes no artwork.
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: artwork).resizable()
                        .frame(width: 68 * s, height: 68 * s)
                        .clipShape(RoundedRectangle(cornerRadius: 12 * s))
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable()
                            .frame(width: 26 * s, height: 26 * s)
                            .clipShape(RoundedRectangle(cornerRadius: 7 * s))
                            .overlay(RoundedRectangle(cornerRadius: 7 * s)
                                .stroke(Color.black.opacity(0.35), lineWidth: s))
                            .offset(x: 5 * s, y: 5 * s)
                    }
                }
            } else if let icon = app.icon {
                Image(nsImage: icon).resizable()
                    .frame(width: 68 * s, height: 68 * s)
                    .clipShape(RoundedRectangle(cornerRadius: 15 * s))
            } else {
                Image(systemName: "app.fill").resizable()
                    .frame(width: 68 * s, height: 68 * s)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 84 * s, height: 84 * s)
        .help(app.trackTitle.map { "\(app.displayName) — \($0)" } ?? app.displayName)
    }
}

/// Rounded-rect function-key badge (F7/F8/F9) shown under each icon in the
/// 2–3 app direct-mapping layout. Just a label with a 2pt border — no fill
/// — matching the reference HUD. Background-adaptive like the transport
/// glyphs: white on a dark backdrop, near-black on a light one.
private struct KeyBadge: View {
    let label: String
    let inverted: Bool
    @Environment(\.hudScale) private var s

    var body: some View {
        Text(label)
            .font(.system(size: 17 * s, weight: .medium))
            .padding(.horizontal, 10 * s)
            .padding(.vertical, 5 * s)
            .overlay(
                RoundedRectangle(cornerRadius: 8 * s)
                    .stroke(inverted ? Color.black : Color.white,
                            lineWidth: 2 * s)
            )
            .foregroundStyle(inverted ? Color.black : Color.white)
            .animation(.easeInOut(duration: 0.25), value: inverted)
    }
}

/// ← ⏸ → transport hints for the 4+ carousel state.
private struct TransportRow: View {
    @ObservedObject var viewModel: SelectorViewModel
    let inverted: Bool
    @Environment(\.hudScale) private var s

    var body: some View {
        // Each glyph is one keycap wide and one pitch from the next, so it
        // sits over the key it stands for (F7 / F8 / F9).
        HStack(spacing: PhysicalMetrics.designGap * s) {
            TransportGlyph(systemName: "arrow.left", active: true)
            TransportGlyph(systemName: "playpause", active: true)
            TransportGlyph(systemName: "arrow.right", active: true)
        }
        .font(.system(size: 30 * s, weight: .semibold))
        // Background-adaptive appearance, home-bar style: the glyph color is
        // a flat monochrome chosen from the averaged luminance of the screen
        // behind the HUD — white when it's dark, near-black when it's light.
        .foregroundStyle(inverted ? Color.black : Color.white)
        .animation(.easeInOut(duration: 0.25), value: inverted)
    }
}

private struct TransportGlyph: View {
    let systemName: String
    let active: Bool
    @Environment(\.hudScale) private var s

    var body: some View {
        Image(systemName: systemName)
            .frame(width: 84 * s, height: 34 * s)
            .opacity(active ? 0.95 : 0.2)
    }
}

/// Infinite carousel for the 4+ selection state.
///
/// Renders the five carousel positions around the view model's unbounded
/// cursor as an HStack. The ForEach's identity IS the position, so a move
/// diffs as a reorder: the four surviving icons slide one slot over while
/// the one crossing the wrap point leaves at the far edge (offscreen, fully
/// faded) and its next-repetition copy enters from the other edge. Because
/// the cursor never wraps, the slide direction never reverses — the loop
/// point is invisible. The selection ring is stationary; icons slide and
/// grow into it.
private struct CarouselRow: View {
    @ObservedObject var viewModel: SelectorViewModel
    @Environment(\.hudScale) private var s

    /// Slot geometry: keycap-wide slots, one key pitch apart.
    private var slotWidth: CGFloat { PhysicalMetrics.designKeycap * s }
    private var slotSpacing: CGFloat { PhysicalMetrics.designGap * s }

    /// Only the inner three slots are fully visible. The clip window is a
    /// bit wider than three slots so the neighbors aren't chopped by the
    /// panel's edges; the outer two slots live past the edge icons
    /// where wrap-related enter/leave transitions stay hidden.
    private var clipWidth: CGFloat { PhysicalMetrics.designContentWidth * s }

    var body: some View {
        let apps = viewModel.state.apps
        let count = apps.count
        let cursor = viewModel.carouselCursor
        // Distinct integers even when the ring wraps (same app in two
        // repetitions gets two positions), so identity is always unique.
        let positions = Array((cursor - 2)...(cursor + 2))

        ZStack {
            HStack(spacing: slotSpacing) {
                ForEach(positions, id: \.self) { position in
                    let wrapped = ((position % count) + count) % count
                    CarouselIconView(app: apps[wrapped],
                                     distance: position - cursor)
                        .transition(.opacity)
                }
            }
            .animation(.interpolatingSpring(stiffness: 420, damping: 34),
                       value: cursor)

            // Stationary selection ring — the centered icon grows into it.
            RoundedRectangle(cornerRadius: 20 * s)
                .stroke(Color.white, lineWidth: 2.5 * s)
                .frame(width: slotWidth, height: slotWidth)
        }
        .frame(width: clipWidth, height: slotWidth)
        .clipped()
    }
}

/// One carousel slot. The center slot sits under the stationary ring at
/// full size; neighbors are scaled down with an animated spring. Anything
/// past the visible three slots is fully transparent. Icons exiting the
/// view blur and fade directionally — the blur rides the slide, and the
/// fade uses an asymmetric linear timing so an entering icon appears early
/// in the move while a leaving icon vanishes just as it crosses the view
/// boundary.
private struct CarouselIconView: View {
    let app: NowPlayingApp
    /// Signed slot distance from the cursor: 0 center, ±1 visible neighbors,
    /// ±2 parked just outside the view.
    let distance: Int
    @Environment(\.hudScale) private var s

    var body: some View {
        AppIconView(app: app)
            .scaleEffect(scale)
            .blur(radius: blur * s)
            .opacity(fade)
            .animation(.interpolatingSpring(stiffness: 480, damping: 36),
                       value: scale)
            .animation(.linear(duration: 0.08).delay(leaving ? 0.05 : 0),
                       value: fade)
            .animation(.easeOut(duration: 0.14), value: blur)
    }

    /// True for the icon instance currently sliding out of the three-slot
    /// view (±1 → ±2). Entering icons (±2 → ±1) fade in immediately instead.
    private var leaving: Bool { abs(distance) == 2 }

    private var scale: CGFloat {
        switch distance {
        case 0: return 1
        case -1, 1: return 0.8
        default: return 0.66
        }
    }

    private var blur: CGFloat {
        switch distance {
        case 0: return 0
        case -1, 1: return 0
        default: return 10
        }
    }

    private var fade: CGFloat {
        switch distance {
        case 0: return 1
        case -1, 1: return 1
        default: return 0
        }
    }
}
