import SwiftUI
import Combine

// ---------------------------------------------------------------------------
// MARK: - SelectorViewModel
// ---------------------------------------------------------------------------
// State machine governing the HUD popup.
//
// States:
//   idle                           — popup hidden
//   showing([NowPlayingApp])       — 2–3 apps, waiting for a media key
//   selecting([NowPlayingApp], Int) — 4+ apps, highlight moves with ⏮/⏭
//
// All transitions happen on the main thread (enforced by callers and @MainActor methods).
// ---------------------------------------------------------------------------

final class SelectorViewModel: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        case showing(apps: [NowPlayingApp])
        case selecting(apps: [NowPlayingApp], selectedIndex: Int)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.showing(let a), .showing(let b)): return a == b
            case (.selecting(let a, let i), .selecting(let b, let j)): return a == b && i == j
            default: return false
            }
        }

        var apps: [NowPlayingApp] {
            switch self {
            case .idle: return []
            case .showing(let apps): return apps
            case .selecting(let apps, _): return apps
            }
        }

        var isIdle: Bool { if case .idle = self { return true }; return false }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var selectedIndex: Int = 0

    // MARK: - Callbacks

    /// Called when a command should be sent. Tuple: (bundleID to command, dismiss).
    var onDispatch: ((String) -> Void)?
    /// Called when the popup should dismiss without sending any command.
    var onDismiss: (() -> Void)?

    // MARK: - Private

    private var timeoutTask: Task<Void, Never>?
    private let timeoutDuration: TimeInterval = 3.0

    // MARK: - Public interface

    @MainActor
    func present(apps: [NowPlayingApp]) {
        cancelTimeout()
        if apps.count >= 4 {
            state = .selecting(apps: apps, selectedIndex: 0)
            selectedIndex = 0
        } else {
            state = .showing(apps: apps)
        }
        scheduleTimeout()
    }

    @MainActor
    func refresh(apps: [NowPlayingApp]) {
        guard !state.isIdle else { return }
        cancelTimeout()
        if apps.count >= 4 {
            let currentIdx = selectedIndex
            let clampedIdx = min(currentIdx, apps.count - 1)
            state = .selecting(apps: apps, selectedIndex: clampedIdx)
            selectedIndex = clampedIdx
        } else if apps.count >= 2 {
            state = .showing(apps: apps)
        } else {
            dismiss()
            return
        }
        scheduleTimeout()
    }

    /// Handle a media key while the popup is visible. Returns true if consumed.
    @discardableResult
    @MainActor
    func handleKey(_ event: MediaKeyEvent) -> Bool {
        switch state {

        // ── 2–3 apps: keys map directly to app indices ──────────────────────
        case .showing(let apps):
            switch event {
            case .previous:
                dispatch(to: apps[0].bundleID)
            case .playPause where apps.count == 3:
                dispatch(to: apps[1].bundleID)
            case .next:
                dispatch(to: (apps.count == 2 ? apps[1] : apps[2]).bundleID)
            default:
                return false
            }
            return true

        // ── 4+ apps: ⏮/⏭ move selection, ⏯ confirms ────────────────────────
        case .selecting(let apps, let idx):
            switch event {
            case .previous:
                let newIdx = (idx - 1 + apps.count) % apps.count
                state = .selecting(apps: apps, selectedIndex: newIdx)
                selectedIndex = newIdx
                resetTimeout()
            case .next:
                let newIdx = (idx + 1) % apps.count
                state = .selecting(apps: apps, selectedIndex: newIdx)
                selectedIndex = newIdx
                resetTimeout()
            case .playPause:
                dispatch(to: apps[idx].bundleID)
            }
            return true

        case .idle:
            return false
        }
    }

    @MainActor
    func dismiss() {
        cancelTimeout()
        state = .idle
        onDismiss?()
    }

    // MARK: - Private

    @MainActor
    private func dispatch(to bundleID: String) {
        cancelTimeout()
        state = .idle
        onDispatch?(bundleID)
    }

    private func scheduleTimeout() {
        let duration = timeoutDuration
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return  // Cancelled
            }
            self?.dismiss()
        }
    }

    private func resetTimeout() {
        cancelTimeout()
        scheduleTimeout()
    }

    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}
