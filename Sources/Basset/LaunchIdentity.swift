import Foundation

/// Which run of the app a reading came from.
///
/// Every other identity the SDK hands out counts from zero when the process
/// starts — the first `AVCaptureSession` of every launch is instance 1 — so
/// without this, readings from two launches on the same device are
/// indistinguishable exactly where it matters: a capture spanning a crash, a
/// relaunch, or a backgrounded app iOS killed.
///
/// Being wrong here produces a wrong reading rather than a missing one. Two
/// merged launches look like one run that stopped and started; deduplicating on
/// identity across that boundary deletes real events, and a timeline built from
/// it interleaves two runs into an order neither had.
///
/// Random rather than counted: a counter needs somewhere to persist, and a launch
/// that crashes before it writes reuses the number of the launch that crashed
/// before it. Sixty-four bits collide at a rate that does not matter for a
/// capture bounded by one request.
public enum LaunchIdentity {
    public static let current: UInt64 = .random(in: 1...UInt64.max)
}
