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
    //
    // IMPORTANT: The callback parameter MUST be Optional<@convention(block)...>.
    // Non-optional @convention(block) parameters in @convention(c) types are
    // treated as @noescape by Swift, which sets BLOCK_IS_NOESCAPE on the block.
    // The C function calls _Block_copy internally (async dispatch), which traps
    // on a noescape block. Optional closures are implicitly @escaping, avoiding
    // the flag entirely.
    private typealias GetClientsFunc = @convention(c) (
        DispatchQueue,
        Optional<@convention(block) (CFArray?) -> Void>
    ) -> Void

    // MRMediaRemoteSendCommandToApp(NSString *, int, NSDictionary *, dispatch_queue_t, ^(BOOL, NSError *))
    // Same Optional trick required for the same reason.
    private typealias SendCommandToAppFunc = @convention(c) (
        CFString,
        Int32,
        CFDictionary?,
        DispatchQueue,
        Optional<@convention(block) (Bool, CFError?) -> Void>
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

    /// Fetches all apps with active Now Playing sessions and delivers the result
    /// on the **main queue** via `completion`. Index 0 = most recently active.
    ///
    /// MRMediaRemoteGetNowPlayingClients makes a synchronous XPC call to
    /// mediaremoted. Calling it directly on the main thread blocks AppKit's
    /// run loop → beachball. We hop to a background thread first, then
    /// deliver results back to main.
    func fetchApps(completion: @escaping ([NowPlayingApp]) -> Void) {
        guard let fnGetClients else {
            print("[NowPlayingService] MRMediaRemoteGetNowPlayingClients unavailable.")
            DispatchQueue.main.async { completion([]) }
            return
        }

        // Must NOT be called from the main thread: the C function may block on XPC.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.fnGetClients!(DispatchQueue.main) { [weak self] cfArray in
                // The C function may fire this on any queue; always hop to main.
                let rawItems = (cfArray as? [AnyObject]) ?? []
                guard let self else { return }
                let apps = self.appsFromRawItems(rawItems)
                DispatchQueue.main.async { completion(apps) }
            }
        }
    }

    // MARK: - Private parsing helper

    private func appsFromRawItems(_ rawItems: [AnyObject]) -> [NowPlayingApp] {
        guard !rawItems.isEmpty else { return [] }

        var bundleIDs: [String] = []
        for (i, item) in rawItems.enumerated() {
            // Log the actual class and description on first item to aid debugging
            if i == 0 {
                print("[NowPlayingService] client[0] class=\(type(of: item)) desc=\(item)")
            }

            if let id = item as? String {
                // Older API: items ARE the bundle ID strings
                bundleIDs.append(id)
            } else {
                // Newer API: items are _MRNowPlayingClientProtocol objects.
                // Try every key name that has been observed across macOS versions.
                let candidates = ["bundleIdentifier", "appBundleIdentifier", "bundleID", "applicationBundleIdentifier"]
                var found: String?
                for key in candidates {
                    if let id = (item as AnyObject).value(forKey: key) as? String {
                        found = id
                        break
                    }
                }

                if let id = found {
                    bundleIDs.append(id)
                } else {
                    // Last resort: ObjC perform on every candidate selector
                    for key in candidates {
                        let sel = NSSelectorFromString(key)
                        if (item as AnyObject).responds(to: sel),
                           let rv = (item as AnyObject).perform(sel),
                           let id = rv.takeUnretainedValue() as? String {
                            bundleIDs.append(id)
                            break
                        }
                    }
                    if bundleIDs.count < i + 1 {
                        print("[NowPlayingService] client[\(i)]: could not extract bundle ID")
                    }
                }
            }
        }

        guard !bundleIDs.isEmpty else {
            print("[NowPlayingService] appsFromRawItems: could not extract bundleIDs from \(rawItems.count) client objects")
            return []
        }

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
                DispatchQueue.main,
                Optional<@convention(block) (Bool, CFError?) -> Void> { success, error in
                    if !success, let error {
                        print("[NowPlayingService] sendCommandToApp failed: \(error)")
                    }
                }
            )
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
