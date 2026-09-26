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

    /// Snapshots started before this moment may predate the last play/pause
    /// we sent (the target app hadn't reacted yet), so they're discarded.
    /// Otherwise a stale "X is playing" would route the next press back to X.
    private var acceptSnapshotsFrom: Date = .distantPast
    private let toggleSettle: TimeInterval = 0.5

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
            let startedAt = Date()
            DispatchQueue.global(qos: .userInitiated).async {
                let (apps, fresh) = self.discoverApps()
                DispatchQueue.main.async {
                    self.store(apps, freshMetadata: fresh, startedAt: startedAt)
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
    /// user presses a media key. Call at launch. `completion`, if given,
    /// gets the cache once the refresh has landed.
    func warmCache(completion: (([NowPlayingApp]) -> Void)? = nil) {
        let startedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let (apps, fresh) = self.discoverApps()
            DispatchQueue.main.async {
                self.store(apps, freshMetadata: fresh, startedAt: startedAt)
                completion?(self.cachedApps)
            }
        }
    }

    /// Writes a discovery result into the cache unless it was started before
    /// the last play/pause settled. Main queue only.
    private func store(_ apps: [NowPlayingApp],
                       freshMetadata: [String: MetadataResult], startedAt: Date) {
        guard startedAt >= acceptSnapshotsFrom else { return }
        cachedApps = finalize(apps, freshMetadata: freshMetadata)
        cacheTime = Date()
    }

    /// Flips the cached play state of the app we just toggled so an immediate
    /// next press sees the new state, then re-checks once the app has had
    /// time to react. Main queue only.
    private func noteToggle(of appID: String) {
        if let i = cachedApps.firstIndex(where: { $0.id == appID }),
           let playing = cachedApps[i].isPlaying {
            cachedApps[i].isPlaying = !playing
        }
        cacheTime = Date()
        acceptSnapshotsFrom = Date().addingTimeInterval(toggleSettle)
        DispatchQueue.main.asyncAfter(deadline: .now() + toggleSettle) { self.warmCache() }
    }

    /// Sends a play/pause toggle to the current Now Playing app.
    ///
    /// osascript-first dispatch: always try to target the picked app directly
    /// via AppleScript (needs a one-time Automation grant per app). Only if
    /// that fails — consent not yet granted, or the app has no AppleScript
    /// dictionary (browsers, Zen) — fall back to the consent-free MediaRemote
    /// adapter, which toggles the *current* now playing app.
    func sendPlayPause(to app: NowPlayingApp) {
        noteToggle(of: app.id)
        let bundleID = app.effectiveBundleID
        DispatchQueue.global(qos: .userInitiated).async {
            // A QuickTime document is driven on its own; the adapter fallback
            // would hit whatever is "now playing", not this document.
            if let document = app.document {
                QuickTimeDocuments.togglePlayPause(document)
                return
            }
            let ok = self.runTargetedAppleScript("playpause", to: bundleID, label: "playpause")
            if !ok { self.sendMediaRemoteCommandSync(.togglePlayPause, label: "playpause (fallback)") }
        }
    }

    /// Pauses every given app: AppleScript `pause` for scriptable apps (per
    /// document for QuickTime). The adapter's pause only reaches the current
    /// now-playing app, so it covers just that one among the rest (apps with
    /// no dictionary, or where AppleScript failed). Pause rather than
    /// toggle, so an app that already stopped stays put. `completion` gets,
    /// on the main queue, the apps actually reached.
    func pauseAll(_ apps: [NowPlayingApp], completion: @escaping ([NowPlayingApp]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var reached = [Bool](repeating: false, count: apps.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: apps.count) { i in
                let app = apps[i]
                var ok = false
                if let document = app.document {
                    ok = QuickTimeDocuments.pause(document)
                } else if Self.scriptableBundleIDs.contains(app.effectiveBundleID) {
                    ok = self.runTargetedAppleScript("pause", to: app.effectiveBundleID, label: "pause")
                }
                lock.lock(); reached[i] = ok; lock.unlock()
            }
            let missed = apps.indices.filter { !reached[$0] }
            if !missed.isEmpty, let nowPlaying = self.currentNowPlayingBundleID(),
               let i = missed.first(where: { apps[$0].document == nil && apps[$0].effectiveBundleID == nowPlaying }) {
                reached[i] = self.sendMediaRemoteCommandSync(.pause, label: "pause (adapter)")
            }
            let paused = apps.indices.filter { reached[$0] }.map { apps[$0] }
            DispatchQueue.main.async {
                let ids = Set(paused.map(\.id))
                // Flip what the cache already lists, but leave its age alone:
                // the hold's fresh discovery never went into it, so it isn't
                // any fresher than before.
                for i in self.cachedApps.indices where ids.contains(self.cachedApps[i].id) {
                    self.cachedApps[i].isPlaying = false
                }
                self.acceptSnapshotsFrom = Date().addingTimeInterval(self.toggleSettle)
                DispatchQueue.main.asyncAfter(deadline: .now() + self.toggleSettle) { self.warmCache() }
                completion(paused)
            }
        }
    }

    /// Sends next-track or previous-track. Same osascript-first rule.
    func sendTrackCommand(_ command: TrackCommand, to app: NowPlayingApp) {
        // QuickTime documents have no tracks; skipping does nothing.
        guard app.document == nil else { return }
        let bundleID = app.effectiveBundleID
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
        case pause = 1             // kMRAPause
        case togglePlayPause = 2   // kMRATogglePlayPause
        case nextTrack = 4         // kMRANextTrack
        case previousTrack = 5     // kMRAPreviousTrack
    }

    /// Spawns the adapter's `send` command and logs the result. The adapter
    /// talks to mediaremoted on our behalf, so no Automation / Apple Events
    /// permission is involved. Call from a background queue (it blocks on
    /// `waitUntilExit`).
    @discardableResult
    private func sendMediaRemoteCommandSync(_ command: MediaRemoteCommand, label: String) -> Bool {
        guard let script = self.perlScriptURL, let framework = self.frameworkURL else {
            Log.write("[NowPlayingService] adapter resources missing; cannot send \(label)")
            return false
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
            return false
        }
        process.waitUntilExit()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus == 0 {
            Log.write("[NowPlayingService] \(label) sent via adapter OK (now-playing)")
            return true
        }
        Log.write("[NowPlayingService] adapter send failed (\(label)): \(errText)")
        return false
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
        let playbackRate: Double?    // > 0 while the app is actually playing
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
    private typealias MetadataResult = (title: String?, rate: Double?,
                                        artwork: NSImage?)

    /// Last-known artwork per app + track, so a paused app's cover survives a
    /// cold-start fetch that returns metadata before the artwork bytes land.
    /// Keyed by effective bundle ID; the track title guards against showing a
    /// stale cover after the track changes.
    private var artworkCache: [String: (trackTitle: String, artwork: NSImage)] = [:]

    /// The last decoded cover per app, keyed by its base64 bytes. Every fetch
    /// returns the same bytes for an unchanged cover; decoding them again
    /// would hand the HUD a new NSImage each refresh, which it (rightly)
    /// treats as a change and redraws. Fetches can overlap, hence the lock.
    private var decodedArtwork: [String: (b64: String, image: NSImage)] = [:]
    private let decodedArtworkLock = NSLock()

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
            if let b64 = app.metadata?.artworkData {
                image = decodeArtwork(b64, for: id)
            }
            result[id] = (app.metadata?.title, app.metadata?.playbackRate, image)
        }
        return result
    }

    private func decodeArtwork(_ b64: String, for id: String) -> NSImage? {
        decodedArtworkLock.lock()
        defer { decodedArtworkLock.unlock() }
        if let hit = decodedArtwork[id], hit.b64 == b64 { return hit.image }
        guard let bytes = Data(base64Encoded: b64), let image = NSImage(data: bytes) else { return nil }
        decodedArtwork[id] = (b64, image)
        return image
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
        // The client list, per-app metadata (artwork + track titles), and the
        // current now-playing app are independent perl spawns that each wait
        // on mediaremoted, so run them side by side instead of back to back.
        // A metadata failure yields an empty map and apps keep their icon-only
        // form.
        var clientsData: Data?
        var freshMetadata: [String: MetadataResult] = [:]
        var nowPlaying: String?
        var quickTimeDocuments: [QuickTimeDocuments.Document]?
        DispatchQueue.concurrentPerform(iterations: 4) { i in
            switch i {
            case 0: clientsData = runAdapter(arguments: [script.path, framework.path, "clients"])
            case 1: freshMetadata = fetchArtworkByBundleID()
            case 2: nowPlaying = currentNowPlayingBundleID()
            default: quickTimeDocuments = QuickTimeDocuments.list()
            }
        }

        guard let data = clientsData else { return ([], [:]) }
        guard let response = try? JSONDecoder().decode(
            AdapterClientsResponse.self, from: data) else {
            Log.write("[NowPlayingService] could not decode clients payload")
            return ([], [:])
        }

        // Collapse helper processes (WebKit GPU, etc.) into their parent app,
        // keyed by the effective bundle ID so each real app appears once.
        var byBundleID: [String: NowPlayingApp] = [:]
        var order: [String] = []
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
                app.isPlaying = (meta.rate ?? 0) > 0
                app.metadataAvailable = true
            }
            if byBundleID[app.effectiveBundleID] == nil {
                order.append(app.effectiveBundleID)
            }
            byBundleID[app.effectiveBundleID] = app
        }

        // QuickTime is one Now Playing client but plays documents
        // independently: list each open document in its place. If it can't
        // be scripted (no Automation grant), keep the single entry.
        if let qt = byBundleID[QuickTimeDocuments.bundleID],
           let documents = quickTimeDocuments, !documents.isEmpty,
           let slot = order.firstIndex(of: QuickTimeDocuments.bundleID) {
            var ids: [String] = []
            for document in documents {
                var app = qt
                app.document = document
                app.isControllable = true
                app.isPlaying = document.playing
                app.metadataAvailable = true
                app.trackTitle = document.name
                app.artwork = document.path.flatMap(QuickTimeDocuments.artwork(forPath:))
                byBundleID[app.id] = app
                ids.append(app.id)
            }
            byBundleID.removeValue(forKey: QuickTimeDocuments.bundleID)
            order.replaceSubrange(slot...slot, with: ids)
        }

        // Alphabetical by app name, so an app keeps its place (and its F-key)
        // from one press to the next. Squatters (Now Playing registrants that
        // aren't actually media players) go last. QuickTime documents sort
        // by file name under QuickTime; the id is a final tiebreak so the
        // order is total.
        let squatters: Set<String> = ["com.rescuetime.RescueTime"]
        func name(_ app: NowPlayingApp) -> String {
            NSRunningApplication.runningApplications(withBundleIdentifier: app.effectiveBundleID)
                .first?.localizedName ?? app.displayName
        }
        let sorted = order.compactMap { byBundleID[$0] }
            .map { (app: $0, name: name($0)) }
            .sorted { a, b in
                let aSq = squatters.contains(a.app.effectiveBundleID)
                let bSq = squatters.contains(b.app.effectiveBundleID)
                if aSq != bSq { return !aSq }
                for (x, y) in [(a.name, b.name),
                               (a.app.document?.name ?? "", b.app.document?.name ?? ""),
                               (a.app.id, b.app.id)] {
                    let order = x.localizedStandardCompare(y)
                    if order != .orderedSame { return order == .orderedAscending }
                }
                return false
            }
            .map(\.app)
        return (sorted, freshMetadata)
    }

    /// Applies the artwork cache on the main queue: fills each app's artwork
    /// from the fresh fetch or, when the fetch raced and returned no bytes, the
    /// last-known cover for the same track. This is the only place the cache is
    /// read or written.
    private func finalize(_ apps: [NowPlayingApp],
                          freshMetadata: [String: MetadataResult]) -> [NowPlayingApp] {
        apps.map { app in
            // QuickTime documents bring their own artwork (QuickLook).
            if app.document != nil { return app }
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
