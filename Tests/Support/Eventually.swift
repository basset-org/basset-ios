import Foundation

/// Waits for a condition the mechanism under test reaches on its own, and
/// reports whether it ever did.
///
/// Sleeping a fixed interval and then asserting once cannot tell a mechanism
/// that fired late from one that never fired: both arrive as the same failed
/// expectation, and the margin that separates them is whatever the machine had
/// to spare that minute. Polling to a deadline removes the margin from the
/// result — the common case returns as soon as the condition holds, and a real
/// failure is one that outlasted a timeout no loaded machine plausibly needs.
///
/// The condition is read on the calling task, so anything it touches must be
/// safe to read from here.
func eventually(
    within timeout: Duration = .seconds(5),
    polling interval: Duration = .milliseconds(20),
    until condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() {
            return true
        }

        // A cancelled sleep throws rather than suspending, so swallowing it
        // turns the wait into a spin that runs the deadline out at full speed.
        do {
            try await Task.sleep(for: interval)
        } catch {
            break
        }
    }

    return condition()
}
