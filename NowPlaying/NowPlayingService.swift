import AppKit
import Foundation

/// Discovers all apps registered with macOS Now Playing, determines each app's
/// play/pause state, and dispatches play/pause to a chosen app.
///
/// Discovery uses the bundled MediaRemote Adapter: on macOS 15.4+ the
/// `mediaremoted` daemon only hands Now Playing data to entitled processes, so
/// we spawn `/usr/bin/perl` (which is entitled) and have it load
/// `MediaRemoteAdapter.framework`, which talks to MediaRemote on our behalf and
/// reports back as JSON. See `Vendor/mediaremote-adapter`.
///
/// State probing and command dispatch use AppleScript, which needs no private
/// API and works for any scriptable media app (Music, Spotify, VLC, …).
final class NowPlayingService {

    static let shared = NowPlayingService()
    private init() {}

    // MARK: - Discovery cache
    //
    // The perl-shim round-trip takes ~0.5–1s. To keep the picker responsive we
    // cache the last result and refresh it in the background whenever it's
    // stale, so a key press can act on slightly-old data instead of blocking.
    private var cachedApps: [NowPlayingApp] = []
    private var cacheTime: Date = .distantPast
    private let cacheTTL: TimeInterval = 3.0
    private var refreshInFlight = false

    // MARK: - Bundle resource paths

    private var perlScriptURL: URL? {
        Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
    }
    private var frameworkURL: URL? {
        Bundle.main.privateFrameworksURL?
            .appendingPathComponent("MediaRemoteAdapter.framework")
    }

    // MARK: - Public API

    /// Fetches every app currently registered with Now Playing (playing and
    /// paused), collapses helper processes into their parent app, and resolves
    /// each app's play/pause state. Delivers on the main queue.
    func fetchApps(completion: @escaping ([NowPlayingApp]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (apps, fresh) = self.discoverApps()
            DispatchQueue.main.async { completion(self.finalize(apps, freshMetadata: fresh)) }
        }
    }

    /// Returns cached apps immediately if fresh; otherwise refreshes async and
    /// delivers the new result. Use this from the key handler so the popup can
    /// open on cached data while a refresh runs.
    func fetchAppsFast(completion: @escaping ([NowPlayingApp]) -> Void) {
        let fresh = Date().timeIntervalSince(cacheTime) < cacheTTL
        if fresh {
            // Serve the cache, then refresh in the background so the *next*
            // press is warm too (membership changes right after a key press).
            warmCache()
            completion(cachedApps)
            return
        }
        if !refreshInFlight {
            refreshInFlight = true
            DispatchQueue.global(qos: .userInitiated).async {
                let (apps, fresh) = self.discoverApps()
                DispatchQueue.main.async {
                    self.cachedApps = self.finalize(apps, freshMetadata: fresh)
                    self.cacheTime = Date()
                    self.refreshInFlight = false
                    completion(self.cachedApps)
                }
            }
        } else {
            // A refresh is already running; serve the (stale) cache now and let
            // the caller decide, rather than queueing a second perl spawn.
            completion(cachedApps)
        }
    }

    /// Kicks off a background refresh so the cache is warm by the time the
    /// user presses a media key. Call at launch.
    func warmCache() {
        DispatchQueue.global(qos: .userInitiated).async {
            let (apps, fresh) = self.discoverApps()
            DispatchQueue.main.async {
                self.cachedApps = self.finalize(apps, freshMetadata: fresh)
                self.cacheTime = Date()
            }
        }
    }

    /// Sends a play/pause toggle to the current Now Playing app.
    ///
    /// osascript-first dispatch: always try to target the picked app directly
    /// via AppleScript (needs a one-time Automation grant per app). Only if
    /// that fails — consent not yet granted, or the app has no AppleScript
    /// dictionary (browsers, Zen) — fall back to the consent-free MediaRemote
    /// adapter, which toggles the *current* now playing app.
    func sendPlayPause(to bundleID: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.runTargetedAppleScript("playpause", to: bundleID, label: "playpause")
            if !ok { self.sendMediaRemoteCommandSync(.togglePlayPause, label: "playpause (fallback)") }
        }
    }

    /// Sends next-track or previous-track. Same osascript-first rule.
    func sendTrackCommand(_ command: TrackCommand, to bundleID: String) {
        let mr: MediaRemoteCommand = (command == .next) ? .nextTrack : .previousTrack
        let label = command == .next ? "next track" : "previous track"
        let verb = command == .next ? "next track" : "previous track"
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.runTargetedAppleScript(verb, to: bundleID, label: label)
            if !ok { self.sendMediaRemoteCommandSync(mr, label: "\(label) (fallback)") }
        }
    }

    // MARK: - Targeted dispatch via AppleScript

    /// Sends a command to a *specific* app via the system `osascript` tool and
    /// returns whether it succeeded. Requires a one-time Automation grant for
    /// the target (error -1743 until approved); apps without an AppleScript
    /// dictionary error too, in which case the caller falls back to the adapter.
    @discardableResult
    private func runTargetedAppleScript(_ verb: String, to bundleID: String, label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application id \"\(bundleID)\" to \(verb)"]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            Log.write("[NowPlayingService] osascript launch failed for \(bundleID): \(error)")
            return false
        }
        process.waitUntilExit()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus == 0 {
            Log.write("[NowPlayingService] \(label) -> \(bundleID) OK (targeted)")
            return true
        } else {
            Log.write("[NowPlayingService] \(label) -> \(bundleID) failed: \(errText)")
            return false
        }
    }

    // MARK: - Command dispatch via the adapter

    /// MediaRemote command numbers (subset of MRCommand used here).
    private enum MediaRemoteCommand: Int {
        case togglePlayPause = 2   // kMRATogglePlayPause
        case nextTrack = 4         // kMRANextTrack
        case previousTrack = 5     // kMRAPreviousTrack
    }

    /// Spawns the adapter's `send` command and logs the result. The adapter
    /// talks to mediaremoted on our behalf, so no Automation / Apple Events
    /// permission is involved. Call from a background queue (it blocks on
    /// `waitUntilExit`).
    private func sendMediaRemoteCommandSync(_ command: MediaRemoteCommand, label: String) {
        guard let script = self.perlScriptURL, let framework = self.frameworkURL else {
            Log.write("[NowPlayingService] adapter resources missing; cannot send \(label)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, framework.path, "send", String(command.rawValue)]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            Log.write("[NowPlayingService] adapter send launch failed (\(label)): \(error)")
            return
        }
        process.waitUntilExit()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus == 0 {
            Log.write("[NowPlayingService] \(label) sent via adapter OK (now-playing)")
        } else {
            Log.write("[NowPlayingService] adapter send failed (\(label)): \(errText)")
        }
    }

    enum TrackCommand {
        case next, previous
    }

    // MARK: - Discovery via the adapter

    private struct AdapterClient: Decodable {
        let bundleIdentifier: String?
        let displayName: String?
        let parentApplicationBundleIdentifier: String?
        let processIdentifier: Int?
    }
    private struct AdapterClientsResponse: Decodable {
        let count: Int
        let clients: [AdapterClient]
    }

    // MARK: - Per-app metadata (artwork) via the adapter's `metadata` command

    private struct AdapterMetadata: Decodable {
        let title: String?
        let artworkData: String?      // base64-encoded image bytes
    }
    private struct AdapterMetadataApp: Decodable {
        let bundleIdentifier: String?
        let parentApplicationBundleIdentifier: String?
        let metadata: AdapterMetadata?
        var effectiveBundleID: String? {
            parentApplicationBundleIdentifier ?? bundleIdentifier
        }
    }
    private struct AdapterMetadataResponse: Decodable {
        let count: Int
        let apps: [AdapterMetadataApp]
    }

    /// One app's metadata fetch result: the track title (nil if the fetch
    /// returned nothing for this app), and artwork (nil when the track has
    /// none or none arrived).
    private typealias MetadataResult = (title: String?, artwork: NSImage?)

    /// Last-known artwork per app + track, so a paused app's cover survives a
    /// cold-start fetch that returns metadata before the artwork bytes land.
    /// Keyed by effective bundle ID; the track title guards against showing a
    /// stale cover after the track changes.
    private var artworkCache: [String: (trackTitle: String, artwork: NSImage)] = [:]

    /// Fetches every registered app's now-playing metadata + artwork via the
    /// adapter's `metadata` command, keyed by effective bundle ID. One-shot;
    /// returns an empty dict on any failure so discovery is never blocked by
    /// artwork availability.
    private func fetchArtworkByBundleID() -> [String: MetadataResult] {
        guard let script = perlScriptURL, let framework = frameworkURL,
              let data = runAdapter(arguments: [script.path, framework.path, "metadata"]),
              let response = try? JSONDecoder().decode(AdapterMetadataResponse.self, from: data)
        else { return [:] }

        var result: [String: MetadataResult] = [:]
        for app in response.apps {
            guard let id = app.effectiveBundleID else { continue }
            var image: NSImage? = nil
            if let b64 = app.metadata?.artworkData,
               let bytes = Data(base64Encoded: b64) {
                image = NSImage(data: bytes)
            }
            result[id] = (app.metadata?.title, image)
        }
        return result
    }

    /// Merges a fresh metadata fetch into the artwork cache and returns the
    /// artwork to show for an app. Only a fetch that actually delivered artwork
    /// updates the cache; an app whose track genuinely has no artwork (metadata
    /// arrived, artwork nil) is recorded as such so an older cover isn't
    /// resurrected. Must be called on the main queue.
    private func resolvedArtwork(for bundleID: String,
                                 fresh: MetadataResult?) -> (title: String?, artwork: NSImage?) {
        guard let fresh else {
            // No metadata for this app at all this fetch — keep whatever we had
            // only if the track is unchanged (we can't tell, so drop it).
            return (nil, nil)
        }
        if let image = fresh.artwork, let title = fresh.title {
            artworkCache[bundleID] = (title, image)
            return (title, image)
        }
        // Metadata arrived but no artwork bytes. If it's the same track we have
        // cached, reuse the cached cover (cold-start race); otherwise this track
        // has no artwork — clear any stale entry.
        if let title = fresh.title, let cached = artworkCache[bundleID],
           cached.trackTitle == title {
            return (title, cached.artwork)
        }
        artworkCache.removeValue(forKey: bundleID)
        return (fresh.title, nil)
    }

    /// Discovers registered apps and fetches fresh per-app metadata. Pure with
    /// respect to the artwork cache (safe to call from a background queue); the
    /// caller passes the raw result to `finalize` on the main queue, which is
    /// where the cache is read and updated.
    private func discoverApps() -> (apps: [NowPlayingApp], freshMetadata: [String: MetadataResult]) {
        guard let script = perlScriptURL, let framework = frameworkURL else {
            Log.write("[NowPlayingService] adapter resources missing from bundle")
            return ([], [:])
        }
        guard let data = runAdapter(arguments: [
            script.path, framework.path, "clients",
        ]) else { return ([], [:]) }

        guard let response = try? JSONDecoder().decode(
            AdapterClientsResponse.self, from: data) else {
            Log.write("[NowPlayingService] could not decode clients payload")
            return ([], [:])
        }

        // Fetch per-app artwork + track titles (a second perl spawn). On any
        // failure this yields an empty map and apps keep their icon-only form.
        let freshMetadata = fetchArtworkByBundleID()

        // Collapse helper processes (WebKit GPU, etc.) into their parent app,
        // keyed by the effective bundle ID so each real app appears once.
        var byBundleID: [String: NowPlayingApp] = [:]
        var order: [String] = []
        let nowPlaying = self.currentNowPlayingBundleID()
        for client in response.clients {
            guard let bundleID = client.bundleIdentifier else { continue }
            var app = NowPlayingApp(
                bundleID: bundleID,
                displayName: client.displayName ?? bundleID,
                processIdentifier: client.processIdentifier.map { pid_t($0) },
                parentBundleID: client.parentApplicationBundleIdentifier
            )
            // An app is reliably controllable if we can drive it directly with
            // AppleScript, or if it's the current now-playing app (reachable
            // via the adapter). Non-scriptable background apps get greyed out.
            app.isControllable = Self.scriptableBundleIDs.contains(app.effectiveBundleID)
                || app.effectiveBundleID == nowPlaying
            if let meta = freshMetadata[app.effectiveBundleID] {
                app.trackTitle = meta.title
                app.metadataAvailable = true
            }
            if byBundleID[app.effectiveBundleID] == nil {
                order.append(app.effectiveBundleID)
            }
            byBundleID[app.effectiveBundleID] = app
        }

        // Sort real media apps first, squatters (Now Playing registrants that
        // aren't actually media players) last, preserving registry order within
        // each group so the picker is stable and predictable.
        let squatters: Set<String> = ["com.rescuetime.RescueTime"]
        let sorted = order.compactMap { byBundleID[$0] }.sorted { a, b in
            let aSq = squatters.contains(a.effectiveBundleID)
            let bSq = squatters.contains(b.effectiveBundleID)
            if aSq != bSq { return !aSq }
            return false  // stable: keep registry order within a group
        }
        return (sorted, freshMetadata)
    }

    /// Applies the artwork cache on the main queue: fills each app's artwork
    /// from the fresh fetch or, when the fetch raced and returned no bytes, the
    /// last-known cover for the same track. This is the only place the cache is
    /// read or written.
    private func finalize(_ apps: [NowPlayingApp],
                          freshMetadata: [String: MetadataResult]) -> [NowPlayingApp] {
        apps.map { app in
            var app = app
            let resolved = resolvedArtwork(for: app.effectiveBundleID,
                                           fresh: freshMetadata[app.effectiveBundleID])
            app.artwork = resolved.artwork
            return app
        }
    }

    /// Bundle IDs known to respond to `tell application id … to playpause`.
    /// Anything not listed here is treated as non-scriptable (browsers, Zen)
    /// and is only controllable while it is the active now-playing app.
    private static let scriptableBundleIDs: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
        "org.videolan.vlc",
        "com.apple.TV",
        "com.apple.Podcasts",
        "com.colliderli.iina",
        "com.cog.cog",
    ]

    /// The bundle ID of the app macOS currently reports as now-playing, read
    /// from the adapter's `get` payload; nil if it can't be determined.
    private func currentNowPlayingBundleID() -> String? {
        guard let script = perlScriptURL, let framework = frameworkURL,
              let data = runAdapter(arguments: [script.path, framework.path, "get"]),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["bundleIdentifier"] as? String
    }

    /// Runs the perl adapter with the given arguments and returns its stdout.
    private func runAdapter(arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            Log.write("[NowPlayingService] failed to launch adapter: \(error)")
            return nil
        }

        // The adapter prints a single JSON line then exits (bounded internally
        // by a hard timeout), so a blocking wait here is safe and bounded.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.isEmpty ? nil : data
    }

    // MARK: - Play/pause state probing

    /// Returns the play/pause state for a bundle ID via AppleScript
    /// (`player state`), or nil if the app isn't scriptable / not running.
    func playbackState(for bundleID: String) -> Bool? {
        let source = "tell application id \"\(bundleID)\" to get player state"
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?
            .executeAndReturnError(&error).stringValue else {
            return nil
        }
        return result.lowercased() == "playing"
    }
}
