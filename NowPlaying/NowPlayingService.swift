import Foundation
import AppKit
import CoreAudio

// ---------------------------------------------------------------------------
// MARK: - NowPlayingService
// ---------------------------------------------------------------------------
// Enumerate audio-outputting processes via the CoreAudio HAL — no private
// API entitlements needed. Route play/pause via MediaRemote's
// MRMediaRemoteSendCommandToApp (works without entitlements).
// ---------------------------------------------------------------------------

final class NowPlayingService {

    // MARK: Singleton
    static let shared = NowPlayingService()

    // MARK: Private — framework handle
    private var frameworkHandle: UnsafeMutableRawPointer?

    // ---------------------------------------------------------------------------
    // Function pointer typedefs for MediaRemote send-command path.
    // These work without special entitlements.
    // ---------------------------------------------------------------------------

    // MRMediaRemoteSendCommandToApp(NSString *, int, NSDictionary *, dispatch_queue_t, ^(BOOL, NSError *))
    // IMPORTANT: callback must be Optional<@convention(block)...> to avoid
    // BLOCK_IS_NOESCAPE trap when the C function calls _Block_copy internally.
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

    /// Returns all apps currently outputting audio, via the CoreAudio HAL.
    /// Delivers results on the **main queue**. Requires macOS 14+; returns
    /// empty on macOS 13.
    func fetchApps(completion: @escaping ([NowPlayingApp]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let apps: [NowPlayingApp]
            if #available(macOS 14, *) {
                apps = self.fetchAppsViaCoreAudio()
            } else {
                apps = []
            }
            print("[NowPlayingService] fetchApps: \(apps.count) app(s) outputting audio")
            DispatchQueue.main.async { completion(apps) }
        }
    }

    // MARK: - CoreAudio enumeration

    /// Enumerates processes currently outputting audio via the CoreAudio HAL.
    /// No private API or special entitlements required.
    @available(macOS 14, *)
    private func fetchAppsViaCoreAudio() -> [NowPlayingApp] {
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObj, &listAddr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            print("[NowPlayingService] CoreAudio: can't get process list size")
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObj, &listAddr, 0, nil, &dataSize, &objectIDs) == noErr else {
            print("[NowPlayingService] CoreAudio: can't get process list")
            return []
        }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        var result: [NowPlayingApp] = []

        for objID in objectIDs {
            // Only include processes actively outputting audio right now.
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunning: UInt32 = 0
            var rSz = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(objID, &runAddr, 0, nil, &rSz, &isRunning) == noErr,
                  isRunning != 0 else { continue }

            // Get the PID of this audio process.
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSz = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &pidSz, &pid) == noErr,
                  pid > 0, pid != ourPID else { continue }

            // Map PID → running app. Skip daemons; only show regular UI apps.
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier,
                  app.activationPolicy == .regular else { continue }

            print("[NowPlayingService] CoreAudio: active output → \(bundleID) (pid=\(pid))")
            result.append(NowPlayingApp(
                id: bundleID,
                icon: app.icon,
                lastActive: Date(),
                isPlaying: true
            ))
        }

        return result
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
