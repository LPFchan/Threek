import Foundation

/// Reads Threek's own privacy grants straight from the TCC service, the way
/// other menu bar utilities do. Unlike `AXIsProcessTrusted` and
/// `CGPreflightScreenCaptureAccess`, the answer isn't cached for the life of
/// the process, and unlike creating an event tap it never shows a prompt.
enum TCC {
    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    /// True if granted, false if denied or not asked yet, nil if the private
    /// function isn't available (callers then fall back to public APIs).
    static func preflight(_ service: String) -> Bool? {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let sym = dlsym(framework, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: Preflight.self)(service as CFString, nil) == 0
    }
}
