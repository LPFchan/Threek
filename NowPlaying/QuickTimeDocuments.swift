import AppKit
import QuickLookThumbnailing

/// QuickTime Player registers with Now Playing as one app, but it can play
/// several documents at once and has no `playpause` / `next track` verbs —
/// its dictionary works per document (`play`, `pause`, `playing`). Threek
/// lists each open document as its own entry and drives it by file path
/// (by name for unsaved recordings, which have no file).
enum QuickTimeDocuments {
    static let bundleID = "com.apple.QuickTimePlayerX"

    struct Document: Hashable {
        let path: String?
        let name: String
        let playing: Bool

        /// Stable identity within QuickTime: the file path, else the name.
        var key: String { path ?? name }
    }

    private static let separator = "\u{1F}"  // ASCII unit separator

    /// QuickTime's open documents, or nil when it isn't running or can't be
    /// scripted (no Automation grant yet). Never launches QuickTime: `tell
    /// application` would, so it's only asked while it's already running.
    static func list() -> [Document]? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil
        else { return nil }
        let source = """
        tell application id "\(bundleID)"
            set out to ""
            repeat with d in documents
                set p to ""
                try
                    set p to POSIX path of (file of d as alias)
                end try
                set out to out & (playing of d) & (ASCII character 31) & (name of d) & (ASCII character 31) & p & linefeed
            end repeat
            return out
        end tell
        """
        guard let output = runOsascript(source) else { return nil }
        return output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: separator)
            guard fields.count == 3 else { return nil }
            return Document(path: fields[2].isEmpty ? nil : fields[2],
                            name: fields[1],
                            playing: fields[0] == "true")
        }
    }

    /// Plays or pauses one document. Returns whether QuickTime accepted it.
    @discardableResult
    static func togglePlayPause(_ document: Document) -> Bool {
        let match = document.path.map { "p is \"\(escape($0))\"" }
            ?? "p is \"\" and name of d is \"\(escape(document.name))\""
        let source = """
        tell application id "\(bundleID)"
            repeat with d in documents
                set p to ""
                try
                    set p to POSIX path of (file of d as alias)
                end try
                if \(match) then
                    if playing of d then
                        pause d
                    else
                        play d
                    end if
                    return "ok"
                end if
            end repeat
        end tell
        error "document not found"
        """
        let ok = runOsascript(source) != nil
        Log.write("[QuickTimeDocuments] playpause -> \(document.name) \(ok ? "OK" : "failed")")
        return ok
    }

    // MARK: - Artwork

    private static var thumbnails: [String: NSImage?] = [:]
    private static let thumbnailLock = NSLock()

    /// The file's own picture as QuickLook renders it — embedded cover art
    /// for audio, a frame for video — or nil when it has none or it isn't
    /// ready yet. Never blocks: the first ask starts QuickLook in the
    /// background and returns nil, so a slow file can't hold up a key press;
    /// a later discovery (the HUD refreshes while it's up) picks the picture
    /// up and animates it in. Cached per path, misses included.
    static func artwork(forPath path: String) -> NSImage? {
        thumbnailLock.lock()
        defer { thumbnailLock.unlock() }
        if let hit = thumbnails[path] { return hit }
        thumbnails[path] = .some(nil)  // in flight; a miss until it lands

        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path), size: CGSize(width: 256, height: 256),
            scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            guard let image = rep?.nsImage else { return }
            thumbnailLock.lock()
            thumbnails[path] = image
            thumbnailLock.unlock()
        }
        return nil
    }

    // MARK: - Helpers

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs AppleScript through `/usr/bin/osascript`, like the rest of the
    /// targeted dispatch, and returns stdout, or nil on failure.
    private static func runOsascript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
