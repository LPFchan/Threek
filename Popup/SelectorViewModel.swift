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
        var isSelecting: Bool {
            if case .selecting = self { return true }
            return false
        }

        /// The selection index when in the 4+ state, else nil.
        var selectedIndex: Int? {
            if case .selecting(_, let i) = self { return i }
            return nil
        }

        /// Three slots shown in the HUD, carousel-style: the selected app is
        /// always the center slot, flanked by its neighbors with wraparound.
        /// For ≤3 apps, all of them in order.
        var windowedApps: [NowPlayingApp] {
            let apps = self.apps
            guard apps.count > 3, let sel = selectedIndex else { return apps }
            return [-1, 0, 1].map { apps[(sel + $0 + apps.count) % apps.count] }
        }
    }

    @Published private(set) var state: State = .idle
    /// The media key that opened the picker; sent to whichever app is chosen.
    private(set) var pendingCommand: MediaKeyEvent = .playPause

    /// Unbounded carousel position. The centered app is always
    /// `apps[cursor % count]`; because the cursor is never wrapped, moving
    /// past either end keeps animating in the same direction instead of
    /// snapping back — the loop point is invisible. `sessionID` changes on
    /// every present so icon identities from a previous HUD never collide.
    @Published private(set) var carouselCursor: Int = 0
    @Published private(set) var sessionID: UUID = UUID()
    /// Average luminance (0–1) of the blurred backdrop behind the HUD,
    /// published on each live-capture frame. Drives the transport glyphs'
    /// background-adaptive light/dark appearance.
    @Published var backdropLuminance: CGFloat = 0

    /// Called with (bundleID, key) when the user confirms an app.
    var onDispatch: ((String, MediaKeyEvent) -> Void)?
    var onDismiss: (() -> Void)?

    private var timeoutTask: Task<Void, Never>?
    private let timeout: TimeInterval = 4.0

    @MainActor
    func present(apps: [NowPlayingApp], triggering: MediaKeyEvent = .playPause) {
        pendingCommand = triggering
        cancelTimeout()
        sessionID = UUID()
        // Uncontrollable apps never enter the picker: they can't receive a
        // command, so showing them greyed out only invites a selection that
        // silently does nothing. Filtering can drop the count below the
        // carousel threshold — fall back to the direct-mapping view.
        let apps = apps.filter(\.isControllable)
        if apps.count >= 4 {
            carouselCursor = 0
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
            // ⏯ only maps to the middle app with three apps; with two it has
            // no badge on screen, so it dismisses instead of acting.
            case .playPause:
                if apps.count == 3 { dispatch(apps[1]) } else { dismiss() }
            case .escape: dismiss()
            case .other: break
            }
            return true
        case .selecting(let apps, let index):
            switch event {
            case .previous:
                let moved = (index - 1 + apps.count) % apps.count
                carouselCursor -= 1
                state = .selecting(apps: apps, selectedIndex: moved)
                resetTimeout()
            case .next:
                let moved = (index + 1) % apps.count
                carouselCursor += 1
                state = .selecting(apps: apps, selectedIndex: moved)
                resetTimeout()
            case .playPause:
                dispatch(apps[index])
            case .escape:
                dismiss()
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
