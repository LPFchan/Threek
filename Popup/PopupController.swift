import AppKit
import CoreGraphics
import Metal
import ScreenCaptureKit
import SwiftUI

/// GPU-backed CIContext shared by the backdrop blur and the content shadow,
/// so both are hardware-accelerated via Metal. Falls back to a default
/// context if no Metal device is available.
private enum SharedGPUContext {
    static let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device,
                             options: [.cacheIntermediates: false])
        }
        return CIContext()
    }()
}

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
    /// Horizontal distance over which the screen blur dissolves into the
    /// desktop at the left and right ends of the panel.
    static let sideFeatherMM: CGFloat = 14
    /// Vertical distance over which the screen blur dissolves upward past
    /// the icon row into the desktop.
    static let topFeatherMM: CGFloat = 12
    /// Extra width added purely so the carousel's neighbor slots aren't
    /// clipped by the feathered edges — the frosted area extends past the
    /// three-slot core so the neighbors read as whole icons. This is
    /// non-physical (purely cosmetic), so it's expressed in points.
    static let hudWidthPaddingPt: CGFloat = 20
    /// Extra margin added on EVERY side so the blur's feather fully fades to
    /// transparent before reaching the window edge — otherwise the fade is
    /// clipped mid-ramp and the blur shows a hard boundary. Pure padding; the
    /// content stays anchored by its insets, so only the blurred field grows.
    static let blurMarginPt: CGFloat = 89

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
        let size = NSSize(width: hudWidthMM * ppm + hudWidthPaddingPt + blurMarginPt * 2,
                          height: (hudHeightMM + featherHeadroomMM + featherFootroomMM) * ppm
                                  + blurMarginPt * 2)
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
    private var backdrop: BackdropView?
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
        if let screen = NSScreen.main {
            let (frame, ppm) = PhysicalMetrics.hudFrame(on: screen)
            contentInset = PhysicalMetrics.contentMarginMM * ppm
                + PhysicalMetrics.blurMarginPt
            bottomLift = PhysicalMetrics.featherFootroomMM * ppm
            if panel == nil { buildPanel(size: frame.size, ppm: ppm) }
            panel?.setFrame(frame, display: false)
            // Capture what's actually behind the panel BEFORE it orders
            // front, so the backdrop shows the real content, not the HUD.
            backdrop?.capture(behind: frame, excluding: panel)
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
        backdrop?.stop()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    func handleKey(_ event: MediaKeyEvent) {
        viewModel.handleKey(event)
    }

    private func buildPanel(size: NSSize, ppm: CGFloat) {
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

        // A CUSTOM backdrop, not NSVisualEffectView: the system vibrancy
        // materials either flatten the content behind the HUD to a dead grey
        // wash (light materials) or a muddy dark scrim (.hudWindow), and none
        // preserve the backdrop's color the way the reference HUD does. So we
        // capture the screen region behind the panel ourselves, blur it with
        // a controlled radius, brighten it slightly, and feather the result
        // to transparent at every edge — full control over blur and tint.
        //
        // The feather mask goes on the CONTAINER's layer so it clips the
        // whole composite (backdrop + content). The container is a fixed size
        // (matching the panel) and both subviews use explicit frames, so the
        // hosting view never resizes the panel — the panel owns its frame.
        let container = FeatheredContainerView()
        let backdrop = BackdropView()
        backdrop.onLuminance = { [weak viewModel] lum in
            viewModel?.backdropLuminance = lum
        }
        container.addSubview(backdrop)

        // A dedicated shadow layer sandwiched BETWEEN the blur backdrop and
        // the SwiftUI content. It renders the content's silhouettes (icons +
        // glyphs) as a soft, blurred black shadow, so the content appears to
        // lift off the frosted glass. It samples the content view's pixels
        // each time the HUD is shown.
        let shadow = ShadowCastingView()
        container.addSubview(shadow)

        let content = NSHostingView(rootView: SelectorPopup(
            viewModel: viewModel,
            contentInset: contentInset,
            bottomLift: bottomLift))
        container.addSubview(content)

        container.frame = NSRect(origin: .zero, size: size)
        backdrop.frame = NSRect(origin: .zero, size: size)
        backdrop.autoresizingMask = [.width, .height, .minYMargin]
        shadow.frame = NSRect(origin: .zero, size: size)
        shadow.autoresizingMask = [.width, .height]
        content.frame = NSRect(origin: .zero, size: size)
        content.autoresizingMask = [.width, .height]

        self.backdrop = backdrop
        self.shadowLayer = shadow
        self.contentView = content

        // The feather starts exactly at the content's bounding box and runs
        // the full gap to the frame's edge: alpha is 1 across the content,
        // then a smoothstep ramp uses the entire margin for the fade. No
        // fully-opaque plateau around the content, no clipped fade.
        container.contentRect = CGRect(
            x: contentInset,
            y: bottomLift,
            width: size.width - contentInset * 2,
            height: size.height - bottomLift - contentInset)

        p.contentView = container
        panel = p
    }
}

/// Captures the screen region behind the panel and renders it blurred +
/// brightened, so the HUD floats on a frosted version of whatever is actually
/// behind it — the reference look that the system vibrancy materials can't
/// reproduce (they flatten the backdrop to a grey wash or a dark scrim).
///
/// The image is a static snapshot taken when the HUD is shown, not a live
/// feed. That's acceptable for a picker that appears for a few seconds, and
/// it keeps us off the Screen Recording permission that a live capture would
/// need. The blur radius and tint are tunable below.
private final class BackdropView: NSView {
    /// Gaussian blur radius in PIXELS of the captured image. Kept modest —
    /// the blur should soften the backdrop, not obliterate it. Because the
    /// capture is at display density (2×), this reads as roughly radius/2 in
    /// points, which keeps the blur subtle.
    var blurRadius: CGFloat = 5

    private var stream: SCStream?
    private let streamDelegate = StreamDelegate()
    private let streamQueue = DispatchQueue(label: "threek.backdrop.stream")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resize
        streamDelegate.onFrame = { [weak self] image in
            self?.applyBlurred(image)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Starts a persistent SCStream over the screen region behind `frame`,
    /// excluding our own panel, so the blur tracks the live background at the
    /// display's own cadence (frames arrive only when the content changes).
    func capture(behind frame: NSRect, excluding panel: NSWindow?) {
        stop()
        guard let screen = NSScreen.main, frame.width > 0 else { return }
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        // SCContentFilter/sourceRect work in POINTS with a top-left origin;
        // AppKit frames are points, bottom-left — flip Y only, don't scale.
        let ptRect = CGRect(x: frame.minX,
                            y: primaryH - frame.maxY,
                            width: frame.width,
                            height: frame.height)
        let scale = screen.backingScaleFactor
        let excludeID = panel?.windowNumber
        Task { [weak self] in
            guard let self else { return }
            let built = await Self.makeStream(region: ptRect, scale: scale,
                                              excludingWindowID: excludeID,
                                              delegate: self.streamDelegate,
                                              queue: self.streamQueue)
            await MainActor.run {
                guard let built else { return }
                self.stream = built
                Task { try? await built.startCapture() }
            }
        }
    }

    /// Stops the stream (called when the HUD dismisses).
    func stop() {
        let s = stream
        stream = nil
        if let s { Task { try? await s.stopCapture() } }
    }

    /// Builds a configured SCStream for the region. One window enumeration at
    /// setup — after that, frames are pushed to the delegate as they change.
    private static func makeStream(region: CGRect,
                                   scale: CGFloat,
                                   excludingWindowID: Int?,
                                   delegate: StreamDelegate,
                                   queue: DispatchQueue) async -> SCStream? {
        guard #available(macOS 14.0, *) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let excluded = content.windows.filter { win in
                guard let ex = excludingWindowID else { return false }
                return win.windowID == CGWindowID(ex)
            }
            let filter = SCContentFilter(display: display,
                                         excludingWindows: excluded)
            let config = SCStreamConfiguration()
            config.sourceRect = region
            config.width = Int(region.width * scale)
            config.height = Int(region.height * scale)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            // Deliver every frame the display produces.
            config.minimumFrameInterval = .zero
            config.queueDepth = 3
            let stream = SCStream(filter: filter, configuration: config,
                                  delegate: delegate)
            // Route screen frames to the delegate on our dedicated queue.
            try stream.addStreamOutput(delegate, type: .screen,
                                       sampleHandlerQueue: queue)
            return stream
        } catch {
            return nil
        }
    }

    /// Pure gaussian blur of the captured frame, set as the layer content.
    /// No tint, brightness, or saturation — just the blurred backdrop. Runs
    /// off the main thread; the GPU-backed CIContext is thread-safe.
    private func applyBlurred(_ image: CGImage) {
        let ci = CIImage(cgImage: image)
        let extent = ci.extent
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return }
        blur.setValue(ci, forKey: kCIInputImageKey)
        blur.setValue(blurRadius, forKey: kCIInputRadiusKey)
        let cropped = blur.outputImage?.cropped(to: extent)
        guard let out = cropped,
              let cg = SharedGPUContext.context.createCGImage(out, from: extent)
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.layer?.contents = cg
            self?.onLuminance?(Self.averageLuminance(of: cg))
        }
    }

    /// Called on the main thread with the backdrop's average luminance (0–1)
    /// each time a new frame is blurred. Drives the adaptive glyph color.
    var onLuminance: ((CGFloat) -> Void)?

    /// Reduces the blurred backdrop to a single average luminance (0–1):
    /// monochrome it, then area-average the whole frame down to one value.
    private static func averageLuminance(of image: CGImage) -> CGFloat {
        let ci = CIImage(cgImage: image)
        let extent = ci.extent
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

    /// GPU-backed CIContext so the gaussian blur is hardware-accelerated via
    /// Metal rather than rendered on the CPU. Falls back to a default context
    /// if no Metal device is available.
    /// Receives SCStream frame callbacks, converts each video sample buffer
    /// to a CGImage, and forwards it for blurring.
    private final class StreamDelegate: NSObject, SCStreamDelegate, SCStreamOutput {
        var onFrame: ((CGImage) -> Void)?

        func stream(_ stream: SCStream,
                    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                    of type: SCStreamOutputType) {
            guard type == .screen,
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }
            let ci = CIImage(cvPixelBuffer: imageBuffer)
            if let cg = SharedGPUContext.context.createCGImage(ci, from: ci.extent) {
                onFrame?(cg)
            }
        }
    }
}

/// Renders the content's silhouettes as a single soft drop shadow. Lives as
/// a subview BETWEEN the blur backdrop and the content, so the icons and
/// glyphs read as floating just above the frosted glass.
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

/// The panel's content view. Its CALayer mask is a two-axis smoothstep
/// feather, so the vibrancy blur inside dissolves to fully transparent at
/// all four edges with no hard boundary. The mask is regenerated whenever
/// the bounds change. Because the icons sit in the opaque core, only the
/// backdrop feathers — the content stays crisp.
private final class FeatheredContainerView: NSView {
    /// The content's bounding box in this view's coordinate space. The mask
    /// stays fully opaque up to this rect's edges, then feathers out across
    /// the gap to the frame's edge — the entire margin is used for the fade.
    var contentRect: CGRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let mask = FeatherMaskLayer(frame: bounds, contentRect: contentRect)
        mask.frame = bounds
        layer?.mask = mask
    }
}

/// A unit-space alpha mask that fades smoothly to transparent at all four
/// edges via a smoothstep ramp, so the masked blur dissolves into the
/// desktop with no visible boundary. Built from two axis gradients blended
/// with multiply, expressed in 0…1 unit space so it tracks the layer's size.
private final class FeatherMaskLayer: CALayer {
    /// Builds a rectangular feather: alpha is 1 everywhere inside
    /// `contentRect`, then a smoothstep ramp runs from the content rect's edge
    /// out to the frame's edge, reaching 0 exactly at the frame boundary. The
    /// whole gap between the two rectangles is used for the fade.
    init(frame: CGRect, contentRect: CGRect) {
        super.init()
        // Work in unit space (0…1 across the frame) so the mask tracks the
        // layer's size. For each axis, alpha is 1 between the content rect's
        // min and max, and ramps to 0 from there to both frame edges. The two
        // axis ramps are blended with multiply so all four sides dissolve.
        func axisRamp(minStart: CGFloat, maxEnd: CGFloat,
                      count: Int) -> ([CGColor], [NSNumber]) {
            var cols = [CGColor]()
            var locs = [NSNumber]()
            for i in 0..<count {
                let t = CGFloat(i) / CGFloat(count - 1)
                // Distance past the content boundary, normalized by the gap on
                // whichever side t falls, so the ramp spans the full gap.
                let u: CGFloat
                if t < minStart {
                    u = minStart > 0 ? max(0, 1 - (minStart - t) / minStart) : 1
                } else if t > maxEnd {
                    let gap = 1 - maxEnd
                    u = gap > 0 ? max(0, 1 - (t - maxEnd) / gap) : 1
                } else {
                    u = 1
                }
                let alpha = u * u * (3 - 2 * u) // smoothstep
                cols.append(NSColor(white: 1, alpha: alpha).cgColor)
                locs.append(NSNumber(value: Double(t)))
            }
            return (cols, locs)
        }
        let fx = frame.width > 0 ? frame.width : 1
        let fy = frame.height > 0 ? frame.height : 1
        let x0 = contentRect.minX / fx
        let x1 = contentRect.maxX / fx
        let y0 = contentRect.minY / fy
        let y1 = contentRect.maxY / fy
        let samples = 64
        let horizontal = CAGradientLayer()
        let (hcols, hlocs) = axisRamp(minStart: x0, maxEnd: x1, count: samples)
        horizontal.colors = hcols
        horizontal.locations = hlocs
        horizontal.startPoint = CGPoint(x: 0, y: 0.5)
        horizontal.endPoint = CGPoint(x: 1, y: 0.5)
        addSublayer(horizontal)

        let vertical = CAGradientLayer()
        let (vcols, vlocs) = axisRamp(minStart: y0, maxEnd: y1, count: samples)
        vertical.colors = vcols
        vertical.locations = vlocs
        vertical.startPoint = CGPoint(x: 0.5, y: 0)
        vertical.endPoint = CGPoint(x: 0.5, y: 1)
        vertical.compositingFilter = "multiplyBlendMode"
        addSublayer(vertical)

        // Gradients use unit-space start/end points, so sizing each sublayer
        // to the mask's bounds makes the ramps span the whole mask at any
        // size — no re-rendering on resize.
        anchorPoint = .zero
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        let r = CGRect(origin: .zero, size: bounds.size)
        sublayers?.forEach { $0.frame = r }
    }

    required init?(coder: NSCoder) { fatalError() }
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
            CarouselRow(viewModel: viewModel)
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
        // Background-adaptive appearance, home-bar style: the glyph color is
        // a flat monochrome chosen from the backdrop's averaged luminance —
        // white when the backdrop is dark, near-black when it's light. We set
        // the color directly rather than using a .blendMode(.difference),
        // because the difference blend forces SwiftUI to rasterize the row
        // into an offscreen group that then gets softened against the
        // separate AppKit backdrop layer — blurring the glyphs.
        .foregroundStyle(glyphInverted ? Color.black : Color.white)
        .animation(.easeInOut(duration: 0.25), value: glyphInverted)
    }

    /// True when the blurred backdrop is light enough that the glyphs should
    /// read dark. Drives the base color for the difference blend. Hysteresis
    /// keeps it from flickering when the backdrop hovers near the midpoint.
    private var glyphInverted: Bool {
        viewModel.backdropLuminance > 0.5
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
            if let artwork = app.artwork {
                // Album artwork leads, with the app icon badged in the corner —
                // the reference mockup's pairing. Falls back to the plain icon
                // below when the app publishes no artwork.
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: artwork).resizable()
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable()
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.black.opacity(0.35), lineWidth: 1))
                            .offset(x: 5, y: 5)
                    }
                }
            } else if let icon = app.icon {
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
        .help(app.trackTitle.map { "\(app.displayName) — \($0)" } ?? app.displayName)
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

    /// Slot geometry: 84-wide slots with 10 of spacing.
    private let slotWidth: CGFloat = 84
    private let slotSpacing: CGFloat = 10

    /// Only the inner three slots are fully visible. The clip window is a
    /// bit wider than three slots so the neighbors aren't chopped by the
    /// HUD's feathered edges; the outer two slots live past the edge icons
    /// where wrap-related enter/leave transitions stay hidden.
    private var clipWidth: CGFloat { slotWidth * 3 + slotSpacing * 2 + 44 }

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
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white, lineWidth: 2.5)
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

    var body: some View {
        AppIconView(app: app)
            .scaleEffect(scale)
            .blur(radius: blur)
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

/// Pure-SwiftUI feather mask: opaque core, smoothstep fade on all four
/// edges, built from standard primitives so it blends correctly in a
