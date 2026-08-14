import Foundation

/// Polls to a deadline instead of a fixed sleep, so a late fire isn't mistaken for none.
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

        // A cancelled sleep throws; swallowing it spins the deadline out at full speed.
        do {
            try await Task.sleep(for: interval)
        } catch {
            break
        }
    }

    return condition()
}
