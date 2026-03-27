import Cocoa
import CoreGraphics

// ---------------------------------------------------------------------------
// MARK: - MediaKeyInterceptor
// ---------------------------------------------------------------------------
// Installs a CGEvent tap at the cghidEventTap level to intercept
// NSSystemDefined media-key events before any other app sees them.
//
// Requires Accessibility permission (AXIsProcessTrusted).
// Call `start()` once the permission is confirmed.
// ---------------------------------------------------------------------------

final class MediaKeyInterceptor {

    // MARK: - Dependencies

    /// Called on MainActor for every key-down media event.
    /// Return `true` to consume (suppress) the event, `false` to pass it through.
    var onKeyDown: ((MediaKeyEvent) -> Bool)?

    /// Called when the event tap is unexpectedly invalidated
    /// (e.g., Accessibility permission revoked at runtime).
    var onTapInvalidated: (() -> Void)?

    // MARK: - Private state

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false

    // NX_KEYTYPE constants from IOKit/hidsystem/ev_keymap.h
    private let NX_KEYTYPE_PLAY: Int32     = 16
    private let NX_KEYTYPE_NEXT: Int32     = 17
    private let NX_KEYTYPE_PREVIOUS: Int32 = 18

    // MARK: - Lifecycle

    /// Start intercepting media keys. Must be called after Accessibility is granted.
    func start() {
        guard !isRunning else { return }

        // The callback needs to reach back into this instance.
        // We use an unretained pointer; the run loop keeps the tap alive.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // We filter on NSSystemDefined (subtype 8) which carries media key data.
        // CGEventType.otherMouseUp == 25 (unused), but NSSystemDefined is not a named
        // CGEventType. We use `NSEventTypeMask.systemDefined.rawValue` → type 14.
        // In practice, subscribing to .other (rawValue 14) covers NSSystemDefined events.
        let eventMask: CGEventMask = 1 << 14  // NSSystemDefined / other

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<MediaKeyInterceptor>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return interceptor.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            print("[MediaKeyInterceptor] Failed to create event tap — Accessibility permission likely missing.")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        print("[MediaKeyInterceptor] Event tap started.")
    }

    /// Stop intercepting and tear down the tap.
    func stop() {
        guard isRunning else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
        print("[MediaKeyInterceptor] Event tap stopped.")
    }

    // MARK: - Event handling

    private func handle(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {

        // Detect tap invalidation (Accessibility revoked, system timeout, etc.)
        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            DispatchQueue.main.async { [weak self] in
                self?.handleTapInvalidated()
            }
            return Unmanaged.passUnretained(event)
        }

        // NSSystemDefined events have rawValue 14 on NSEvent side.
        // From CGEvent we get type.rawValue == 14 for "other".
        guard type.rawValue == 14 else {
            return Unmanaged.passUnretained(event)
        }

        // Use NSEvent to decode the media-key packed data
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int32((nsEvent.data1 & 0xFFFF0000) >> 16)
        let keyFlags = nsEvent.data1 & 0x0000FFFF
        let isKeyDown = (keyFlags & 0x0100) == 0 // bit 8 clear = key pressed

        guard isKeyDown else {
            // Key-up: always pass through (we only act on key-down)
            return Unmanaged.passUnretained(event)
        }

        let mediaEvent: MediaKeyEvent
        switch keyCode {
        case NX_KEYTYPE_PLAY:     mediaEvent = .playPause
        case NX_KEYTYPE_NEXT:     mediaEvent = .next
        case NX_KEYTYPE_PREVIOUS: mediaEvent = .previous
        default:
            return Unmanaged.passUnretained(event)
        }

        // Ask the handler (on main thread) whether to consume
        var shouldConsume = false
        if Thread.isMainThread {
            shouldConsume = onKeyDown?(mediaEvent) ?? false
        } else {
            DispatchQueue.main.sync {
                shouldConsume = self.onKeyDown?(mediaEvent) ?? false
            }
        }

        if shouldConsume {
            return nil  // Consumed — event goes no further
        }
        return Unmanaged.passUnretained(event)  // Pass through
    }

    // MARK: - Tap invalidation

    private func handleTapInvalidated() {
        // Called on main thread via async dispatch
        print("[MediaKeyInterceptor] Event tap invalidated.")
        stop()  // Clean up state and run loop source
        onTapInvalidated?()
    }
}
