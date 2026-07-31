import Cocoa
import CoreGraphics

/// Installs a CGEvent tap at the HID level to intercept hardware media-key
/// events before any app sees them. Requires Accessibility permission.
final class MediaKeyInterceptor {

    /// Called on the main thread for every key-down media event.
    /// Return `true` to consume (suppress), `false` to pass through.
    var onKeyDown: ((MediaKeyEvent) -> Bool)?

    /// Called when the event tap is invalidated (e.g. permission revoked).
    var onTapInvalidated: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false

    /// Set true the first time any system-defined event actually reaches the
    /// tap. Until this fires, `AXIsProcessTrusted()` may report true while the
    /// tap silently receives nothing (stale TCC grant after a rebuild).
    private(set) var hasSeenEvent = false

    // NX_KEYTYPE constants from IOKit/hidsystem/ev_keymap.h
    private let NX_KEYTYPE_PLAY: Int32 = 16
    private let NX_KEYTYPE_NEXT: Int32 = 17
    private let NX_KEYTYPE_PREVIOUS: Int32 = 18

    // Ordinary keyboard key codes for the F-keys the user may remap their
    // media keys to (e.g. via Karabiner). These arrive as normal keyDown
    // events, not systemDefined media events, so we watch for them too.
    private let kVK_F17: Int64 = 64
    private let kVK_F18: Int64 = 79
    private let kVK_F19: Int64 = 80
    private let kVK_Escape: Int64 = 53

    func start() {
        guard !isRunning else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Watch two event classes:
        //  - CGEventType 14 (NSSystemDefined): the native hardware media keys.
        //  - CGEventType 10 (.keyDown): F17/18/19 when the user has remapped
        //    their media keys to plain F-keys (Karabiner).
        let eventMask: CGEventMask = (1 << 14) | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<MediaKeyInterceptor>
                    .fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            Log.write("[MediaKeyInterceptor] tap creation failed")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        Log.write("[MediaKeyInterceptor] tap started")
    }

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
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            // macOS auto-disables a tap whose callback is too slow. Re-enable
            // it so media keys don't go dead silently after a hiccup.
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onTapInvalidated?()   // still notify, but tap stays alive
            }
            return Unmanaged.passUnretained(event)
        }

        // Ordinary key events (F17/18/19 remaps).
        if type == .keyDown {
            return handleOrdinaryKey(event)
        }

        // System-defined (native media key) events.
        guard type.rawValue == 14,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        hasSeenEvent = true

        let keyCode = Int32((nsEvent.data1 & 0xFFFF0000) >> 16)
        let keyFlags = nsEvent.data1 & 0x0000FFFF
        let isKeyDown = (keyFlags & 0x0100) == 0
        guard isKeyDown else { return Unmanaged.passUnretained(event) }

        let mediaEvent: MediaKeyEvent
        switch keyCode {
        case NX_KEYTYPE_PLAY: mediaEvent = .playPause
        case NX_KEYTYPE_NEXT: mediaEvent = .next
        case NX_KEYTYPE_PREVIOUS: mediaEvent = .previous
        default: mediaEvent = .other(keyCode)
        }

        var consume = false
        if Thread.isMainThread {
            consume = onKeyDown?(mediaEvent) ?? false
        } else {
            DispatchQueue.main.sync { consume = self.onKeyDown?(mediaEvent) ?? false }
        }
        return consume ? nil : Unmanaged.passUnretained(event)
    }

    /// Handles a plain keyDown event. Returns nil to consume F17/18/19 (so
    /// they don't leak through to other apps), or passes everything else on.
    private func handleOrdinaryKey(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Ignore autorepeat so holding the key doesn't spam play/pause.
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard !isRepeat else { return Unmanaged.passUnretained(event) }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let mediaEvent: MediaKeyEvent
        switch code {
        case kVK_F17: mediaEvent = .previous
        case kVK_F18: mediaEvent = .playPause
        case kVK_F19: mediaEvent = .next
        case kVK_Escape: mediaEvent = .escape
        default: return Unmanaged.passUnretained(event)
        }
        hasSeenEvent = true

        var consume = false
        if Thread.isMainThread {
            consume = onKeyDown?(mediaEvent) ?? false
        } else {
            DispatchQueue.main.sync { consume = self.onKeyDown?(mediaEvent) ?? false }
        }
        return consume ? nil : Unmanaged.passUnretained(event)
    }
}
