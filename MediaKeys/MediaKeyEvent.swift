import Foundation

/// The hardware media keys Threek acts on.
enum MediaKeyEvent {
    case previous
    case playPause
    case next
    /// Any other system-defined key (used for the tap-health canary).
    case other(Int32)

    /// The NX_KEYTYPE_* value, so handlers can identify a canary key.
    var rawKeyCode: Int32 {
        switch self {
        case .previous: return 18
        case .playPause: return 16
        case .next: return 17
        case .other(let code): return code
        }
    }
}
