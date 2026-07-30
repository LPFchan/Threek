import Combine
import Foundation

/// State machine for the HUD popup.
///
/// - `idle`: hidden
/// - `showing`: 2–3 apps, media keys map directly to app indices
/// - `selecting`: 4+ apps, move selection, play/pause confirms
final class SelectorViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case showing(apps: [NowPlayingApp])
        case selecting(apps: [NowPlayingApp], selectedIndex: Int)

        var apps: [NowPlayingApp] {
            switch self {
            case .idle: return []
            case .showing(let a): return a
            case .selecting(let a, _): return a
            }
        }
        var isIdle: Bool { self == .idle }
    }

    @Published private(set) var state: State = .idle
    /// The media key that opened the picker; sent to whichever app is chosen.
    private(set) var pendingCommand: MediaKeyEvent = .playPause

    /// Called with (bundleID, key) when the user confirms an app.
    var onDispatch: ((String, MediaKeyEvent) -> Void)?
    var onDismiss: (() -> Void)?

    private var timeoutTask: Task<Void, Never>?
    private let timeout: TimeInterval = 4.0

    @MainActor
    func present(apps: [NowPlayingApp], triggering: MediaKeyEvent = .playPause) {
        pendingCommand = triggering
        cancelTimeout()
        if apps.count >= 4 {
            state = .selecting(apps: apps, selectedIndex: 0)
        } else {
            state = .showing(apps: apps)
        }
        scheduleTimeout()
    }

    @MainActor
    @discardableResult
    func handleKey(_ event: MediaKeyEvent) -> Bool {
        switch state {
        case .showing(let apps):
            switch event {
            case .previous: dispatch(apps[0])
            case .next: dispatch(apps[apps.count == 2 ? 1 : 2])
            case .playPause: dispatch(apps[apps.count == 3 ? 1 : 0])
            case .other: break
            }
            return true
        case .selecting(let apps, let index):
            switch event {
            case .previous:
                state = .selecting(apps: apps,
                                   selectedIndex: (index - 1 + apps.count) % apps.count)
                resetTimeout()
            case .next:
                state = .selecting(apps: apps,
                                   selectedIndex: (index + 1) % apps.count)
                resetTimeout()
            case .playPause:
                dispatch(apps[index])
            case .other:
                break
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

    @MainActor
    private func dispatch(_ app: NowPlayingApp) {
        cancelTimeout()
        state = .idle
        onDispatch?(app.effectiveBundleID, pendingCommand)
    }

    private func scheduleTimeout() {
        let duration = timeout
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
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
