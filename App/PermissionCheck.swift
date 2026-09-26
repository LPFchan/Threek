import ApplicationServices
import CoreGraphics
import Foundation

/// Asks macOS about Threek's own permissions from a fresh copy of Threek.
///
/// `AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess` and the TCC
/// service all answer from a per-process cache: once asked, they keep that
/// answer for the life of the app, so a grant or revocation made in System
/// Settings never shows up. Making a test event tap does see the live state,
/// but on a Mac where Threek was never asked it raises the stock prompt.
/// A short-lived child process started from Threek's own binary has no cache
/// yet, macOS attributes it to Threek, and it just reports and exits.
enum PermissionCheck {
    enum Permission: String { case accessibility, screen, both }

    private static let flag = "--check-permission"

    /// Called first thing at launch: when started as a checker, answer
    /// through the exit status and quit before any UI exists.
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count,
              let permission = Permission(rawValue: args[i + 1]) else { return }
        switch permission {
        case .accessibility: exit(AXIsProcessTrusted() ? 0 : 1)
        case .screen: exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
        // Bit 0 set: no Accessibility; bit 1 set: no Screen Recording.
        case .both: exit((AXIsProcessTrusted() ? 0 : 1) | (CGPreflightScreenCaptureAccess() ? 0 : 2))
        }
    }

    /// Accessibility and Screen Recording from a single child.
    static func both() -> (accessibility: Bool, screen: Bool) {
        guard let status = run(.both) else {
            return (AXIsProcessTrusted(), CGPreflightScreenCaptureAccess())
        }
        return (status & 1 == 0, status & 2 == 0)
    }

    /// Whether Threek has `permission` right now. Blocks for the child's run
    /// (tens of milliseconds); falls back to the in-process answer if it
    /// can't start one.
    static func has(_ permission: Permission) -> Bool {
        guard let status = run(permission) else {
            return permission == .accessibility ? AXIsProcessTrusted() : CGPreflightScreenCaptureAccess()
        }
        return status == 0
    }

    /// Runs a checker and returns its exit status, or nil if it can't start.
    private static func run(_ permission: Permission) -> Int32? {
        let checker = Process()
        checker.executableURL = Bundle.main.executableURL
        checker.arguments = [flag, permission.rawValue]
        checker.standardOutput = FileHandle.nullDevice
        checker.standardError = FileHandle.nullDevice
        do { try checker.run() } catch { return nil }
        checker.waitUntilExit()
        return checker.terminationStatus
    }
}
