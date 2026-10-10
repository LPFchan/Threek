import Foundation

extension Process {
    /// Stops the process if it's still running `seconds` from now. Call right
    /// after `run()`, before reading its output, so a child that never exits
    /// can't hold the caller forever. After it exits,
    /// `terminationReason == .uncaughtSignal` means it was stopped.
    func terminate(after seconds: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            if isRunning { terminate() }
        }
    }
}
