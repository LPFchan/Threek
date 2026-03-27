import Foundation
import AppKit

// ---------------------------------------------------------------------------
// MARK: - NowPlayingService
// ---------------------------------------------------------------------------
// Wraps the private MediaRemote.framework via dlopen/dlsym.
//
// Key design notes:
// - MRMediaRemoteGetNowPlayingApplications: async, returns array of bundleIDs
//   ordered most-recently-active first by the OS.
// - MRMediaRemoteGetNowPlayingInfo: async, returns info for the *currently active*
//   Now Playing app globally (no per-bundleID variant in the APIs we use).
// - MRMediaRemoteSendCommandToApp: sends a command to a *specific* app by bundleID —
//   the correct targeted dispatch API.
// - MRMediaRemoteSendCommand: global fallback, sends to the currently active app.
// ---------------------------------------------------------------------------

final class NowPlayingService {

    // MARK: Singleton
    static let shared = NowPlayingService()

    // MARK: Private — framework handle
    private var frameworkHandle: UnsafeMutableRawPointer?

    // ---------------------------------------------------------------------------
    // Function pointer typedefs
    // ---------------------------------------------------------------------------

    // MRMediaRemoteGetNowPlayingApplications(dispatch_queue_t, ^(NSArray<NSString*>*))
    private typealias GetAppsFunc = @convention(c) (
        DispatchQueue,
        @escaping (NSArray) -> Void
    ) -> Void

    // MRMediaRemoteSendCommandToApp(NSString*, MRMediaRemoteCommand, NSDictionary*, dispatch_queue_t, ^(BOOL, NSError*))
    private typealias SendCommandToAppFunc = @convention(c) (
        CFString,       // bundleID
        Int32,          // command (MRMediaRemoteCommand)
        CFDictionary?,  // options (may be NULL)
        DispatchQueue,  // completion queue
        @escaping (Bool, CFError?) -> Void
    ) -> Void

    // Fallback: MRMediaRemoteSendCommand(MRMediaRemoteCommand, NSDictionary*)
    private typealias SendCommandFunc = @convention(c) (
        Int32,         // command
        CFDictionary?  // options (may be NULL)
    ) -> Bool

    // ---------------------------------------------------------------------------
    // Resolved function pointers
    // ---------------------------------------------------------------------------
    private var fnGetApps: GetAppsFunc?
    private var fnSendCommandToApp: SendCommandToAppFunc?
    private var fnSendCommand: SendCommandFunc?

    // MARK: Init
    private init() {
        loadFramework()
    }

    // MARK: - Framework Loading

    private func loadFramework() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            print("[NowPlayingService] Failed to load MediaRemote: \(String(cString: dlerror()))")
            return
        }
        frameworkHandle = handle

        if let ptr = dlsym(handle, "MRMediaRemoteGetNowPlayingApplications") {
            fnGetApps = unsafeBitCast(ptr, to: GetAppsFunc.self)
        } else {
            print("[NowPlayingService] MRMediaRemoteGetNowPlayingApplications not found.")
        }

        if let ptr = dlsym(handle, "MRMediaRemoteSendCommandToApp") {
            fnSendCommandToApp = unsafeBitCast(ptr, to: SendCommandToAppFunc.self)
        }

        if let ptr = dlsym(handle, "MRMediaRemoteSendCommand") {
            fnSendCommand = unsafeBitCast(ptr, to: SendCommandFunc.self)
        }
    }

    // MARK: - Public API

    /// Returns all apps with active Now Playing sessions.
    /// The OS returns them most-recently-active first; we preserve that order.
    func fetchApps() async -> [NowPlayingApp] {
        guard let fnGetApps else {
            print("[NowPlayingService] MRMediaRemoteGetNowPlayingApplications unavailable.")
            return []
        }

        let bundleIDs: [String] = await withCheckedContinuation { continuation in
            fnGetApps(DispatchQueue.global(qos: .userInitiated)) { nsArray in
                let ids = nsArray as? [String] ?? []
                continuation.resume(returning: ids)
            }
        }

        guard !bundleIDs.isEmpty else { return [] }

        // Build app models preserving OS ordering (index 0 = most recently active).
        // Assign a synthetic lastActive date based on index so sort is stable.
        let now = Date()
        var apps: [NowPlayingApp] = []
        for (index, bundleID) in bundleIDs.enumerated() {
            let icon = resolveIcon(for: bundleID)
            let syntheticDate = now.addingTimeInterval(-Double(index))
            apps.append(NowPlayingApp(
                id: bundleID,
                icon: icon,
                lastActive: syntheticDate,
                isPlaying: true  // All apps returned by MediaRemote have active sessions
            ))
        }
        return apps
    }

    /// Sends a play/pause toggle to the specified app by bundle ID.
    /// Uses MRMediaRemoteSendCommandToApp (targeted) when available.
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

        // Fallback: set as active app then send globally
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
