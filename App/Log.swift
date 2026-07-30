import Foundation

/// Tiny synchronous file logger. Threek's stdout is unreliable when the app is
/// launched detached (SwiftUI buffers it and nothing flushes), so diagnostics
/// go straight to a file with an explicit flush after every line.
enum Log {
    private static let url = URL(fileURLWithPath:
        NSHomeDirectory()).appendingPathComponent("Library/Logs/Threek.log")
    private static let handle: FileHandle? = {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: url)
    }()

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let data = line.data(using: .utf8), let handle {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.synchronize()
        }
    }
}
