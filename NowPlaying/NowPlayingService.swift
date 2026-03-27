import Foundation
import AppKit

// ---------------------------------------------------------------------------
// MARK: - NowPlayingService
// ---------------------------------------------------------------------------
// Wraps the private MediaRemote.framework via dlopen/dlsym.
//
// Critical loading notes:
// - Load via NSBundle first so the linker resolves internal references,
//   AND dlopen with RTLD_GLOBAL so RTLD_DEFAULT lookups work on macOS 13+.
// - Completion handlers ARE Objective-C blocks → must use @convention(block).
//   Using a plain Swift closure (@escaping) as a @convention(c) function
//   parameter prevents Swift from bridging it correctly.
// ---------------------------------------------------------------------------

final class NowPlayingService {

    // MARK: Singleton
    static let shared = NowPlayingService()

    // MARK: Private — framework handle
    private var frameworkHandle: UnsafeMutableRawPointer?

    // ---------------------------------------------------------------------------
    // Function pointer typedefs — ObjC blocks use @convention(block)
    // ---------------------------------------------------------------------------

    // MRMediaRemoteGetNowPlayingClients(dispatch_queue_t, ^(NSArray *clients))
    // Renamed from MRMediaRemoteGetNowPlayingApplications in later macOS.
    // Each element is an _MRNowPlayingClientProtocol ObjC object with
    // `bundleIdentifier` and `displayName` properties.
    private typealias GetClientsFunc = @convention(c) (
        DispatchQueue,
        @convention(block) (CFArray?) -> Void
    ) -> Void

    // MRMediaRemoteSendCommandToApp(NSString *, int, NSDictionary *, dispatch_queue_t, ^(BOOL, NSError *))
    private typealias SendCommandToAppFunc = @convention(c) (
        CFString,
        Int32,
        CFDictionary?,
        DispatchQueue,
        @convention(block) (Bool, CFError?) -> Void
    ) -> Void

    // MRMediaRemoteSendCommand(int, NSDictionary *) → BOOL
    private typealias SendCommandFunc = @convention(c) (
        Int32,
        CFDictionary?
    ) -> Bool

    // ---------------------------------------------------------------------------
    // Resolved function pointers
    // ---------------------------------------------------------------------------
    private var fnGetClients: GetClientsFunc?
    private var fnSendCommandToApp: SendCommandToAppFunc?
    private var fnSendCommand: SendCommandFunc?

    // MARK: Init
    private init() {
        loadFramework()
    }

    // MARK: - Framework Loading

    private func loadFramework() {
        let frameworkDir  = "/System/Library/PrivateFrameworks/MediaRemote.framework"
        let frameworkBin  = frameworkDir + "/MediaRemote"

        // Step 1: Load via NSBundle so its internal ObjC classes / static initializers run.
        let bundle = Bundle(path: frameworkDir)
        if bundle?.isLoaded == false {
            bundle?.load()
        }

        // Step 2: dlopen with RTLD_GLOBAL so RTLD_DEFAULT can find the symbols.
        //         If the binary was already mapped (by NSBundle), RTLD_NOLOAD returns the handle.
        if let handle = dlopen(frameworkBin, RTLD_LAZY | RTLD_GLOBAL) {
            frameworkHandle = handle
        } else if let handle = dlopen(frameworkBin, RTLD_NOLOAD) {
            frameworkHandle = handle
        } else {
            print("[NowPlayingService] dlopen failed: \(String(cString: dlerror()))")
        }

        // Step 3: Resolve symbols — prefer specific handle, fall back to RTLD_DEFAULT.
        // RTLD_DEFAULT (-2 as UnsafeMutableRawPointer) searches all loaded images.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

        func sym(_ name: String) -> UnsafeMutableRawPointer? {
            if let h = frameworkHandle, let p = dlsym(h, name) { return p }
            if let p = dlsym(rtldDefault, name) { return p }
            print("[NowPlayingService] Symbol not found: \(name)")
            return nil
        }

        // Prefer the newer name; fall back to the older one for pre-macOS-15 compatibility.
        if let p = sym("MRMediaRemoteGetNowPlayingClients") {
            fnGetClients = unsafeBitCast(p, to: GetClientsFunc.self)
            print("[NowPlayingService] ✓ MRMediaRemoteGetNowPlayingClients")
        } else if let p = sym("MRMediaRemoteGetNowPlayingApplications") {
            // Older name returns [NSString] (bundle IDs directly).
            // We reuse the same signature — the block param behaves identically.
            fnGetClients = unsafeBitCast(p, to: GetClientsFunc.self)
            print("[NowPlayingService] ✓ MRMediaRemoteGetNowPlayingApplications (legacy)")
        } else {
            print("[NowPlayingService] ✗ No Now Playing clients API found.")
        }
        if let p = sym("MRMediaRemoteSendCommandToApp") {
            fnSendCommandToApp = unsafeBitCast(p, to: SendCommandToAppFunc.self)
            print("[NowPlayingService] ✓ MRMediaRemoteSendCommandToApp")
        }
        if let p = sym("MRMediaRemoteSendCommand") {
            fnSendCommand = unsafeBitCast(p, to: SendCommandFunc.self)
            print("[NowPlayingService] ✓ MRMediaRemoteSendCommand")
        }
    }

    // MARK: - Public API

    /// Returns all apps with active Now Playing sessions.
    /// The OS returns them most-recently-active first; we preserve that order.
    func fetchApps() async -> [NowPlayingApp] {
        guard let fnGetClients else {
            print("[NowPlayingService] MRMediaRemoteGetNowPlayingClients unavailable.")
            return []
        }

        let rawItems: [AnyObject] = await withCheckedContinuation { continuation in
            fnGetClients(DispatchQueue.global(qos: .userInitiated)) { cfArray in
                let items = (cfArray as? [AnyObject]) ?? []
                continuation.resume(returning: items)
            }
        }

        guard !rawItems.isEmpty else { return [] }

        // Each item is EITHER:
        //  • An NSString (bundle ID) — older macOS / older API name
        //  • An _MRNowPlayingClientProtocol ObjC object — newer macOS
        //    with a `bundleIdentifier` property.
        var bundleIDs: [String] = []
        for item in rawItems {
            if let id = item as? String {
                bundleIDs.append(id)
            } else if let id = (item as AnyObject).value(forKey: "bundleIdentifier") as? String {
                bundleIDs.append(id)
            } else {
                // Last resort: ObjC perform
                let sel = NSSelectorFromString("bundleIdentifier")
                if (item as AnyObject).responds(to: sel),
                   let rv = (item as AnyObject).perform(sel),
                   let id = rv.takeUnretainedValue() as? String {
                    bundleIDs.append(id)
                }
            }
        }

        guard !bundleIDs.isEmpty else {
            print("[NowPlayingService] fetchApps: could not extract bundleIDs from \(rawItems.count) client objects")
            return []
        }

        // Preserve OS ordering (index 0 = most recently active).
        let now = Date()
        return bundleIDs.enumerated().map { (index, bundleID) in
            NowPlayingApp(
                id: bundleID,
                icon: resolveIcon(for: bundleID),
                lastActive: now.addingTimeInterval(-Double(index)),
                isPlaying: true
            )
        }
    }

    /// Sends a play/pause toggle to the specified app by bundle ID.
    func sendPlayPause(to bundleID: String) {
        let kMRTogglePlayPause: Int32 = 2

        if let fnSendCommandToApp {
            fnSendCommandToApp(
                bundleID as CFString,
                kMRTogglePlayPause,
                nil,
                DispatchQueue.main
            ) { success, error in
                if !success, let error {
                    print("[NowPlayingService] sendCommandToApp failed: \(error)")
                }
            }
            return
        }

        // Fallback: set active app override then send globally
        setNowPlayingAppOverride(bundleID: bundleID)
        if let fnSendCommand {
            _ = fnSendCommand(kMRTogglePlayPause, nil)
        } else {
            print("[NowPlayingService] No send command function available.")
        }
    }

    // MARK: - Private helpers

    private func resolveIcon(for bundleID: String) -> NSImage? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return running.icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private func setNowPlayingAppOverride(bundleID: String) {
        guard let handle = frameworkHandle,
              let ptr = dlsym(handle, "MRMediaRemoteSetNowPlayingApplicationOverride") else { return }
        typealias SetOverrideFunc = @convention(c) (CFString) -> Void
        let fn = unsafeBitCast(ptr, to: SetOverrideFunc.self)
        fn(bundleID as CFString)
    }
}
