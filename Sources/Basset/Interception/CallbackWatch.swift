import Darwin
import Foundation

/// Which callbacks are armed, and each one's stack once it ran past its threshold. Decisions only.
struct CallbackWatch: Equatable {
    struct Armed: Equatable {
        let token: UInt64
        let thread: thread_t
        let deadlineNanoseconds: UInt64
    }

    private(set) var armed: [UInt64: Armed] = [:]
    private(set) var captured: [UInt64: [UInt64]] = [:]

    var isIdle: Bool {
        armed.isEmpty
    }

    var earliestDeadlineNanoseconds: UInt64? {
        armed.values.map(\.deadlineNanoseconds).min()
    }

    mutating func enter(
        _ token: UInt64,
        on thread: thread_t,
        at nowNanoseconds: UInt64,
        threshold: UInt64
    ) {
        armed[token] = Armed(
            token: token,
            thread: thread,
            deadlineNanoseconds: nowNanoseconds &+ threshold
        )
        captured.removeValue(forKey: token)
    }

    /// Every armed callback whose deadline has passed, earliest first.
    func due(at nowNanoseconds: UInt64) -> [Armed] {
        armed.values
            .filter { nowNanoseconds >= $0.deadlineNanoseconds }
            .sorted { $0.deadlineNanoseconds < $1.deadlineNanoseconds }
    }

    /// Disarms too: one walk per callback, however long it goes on.
    mutating func capture(_ frames: [UInt64], for token: UInt64) {
        guard armed.removeValue(forKey: token) != nil else {
            return
        }

        captured[token] = frames
    }

    /// The frames walked while this callback ran, if it ran long enough to be walked.
    mutating func leave(_ token: UInt64) -> [UInt64]? {
        armed.removeValue(forKey: token)
        return captured.removeValue(forKey: token)
    }
}

/// One token stack per calling thread: a leave on one delivery queue never takes another's.
struct InFlightTokens: Equatable {
    struct Held: Equatable {
        var tokens: [UInt64?]
        var refused: Int
    }

    static let depth = 8

    private(set) var byThread: [thread_t: Held] = [:]

    init() {
        byThread.reserveCapacity(4)
    }

    private static func emptyHeld() -> Held {
        var tokens = [UInt64?]()
        tokens.reserveCapacity(depth)
        return Held(tokens: tokens, refused: 0)
    }

    /// A call that never armed pushes nil, so that pops stay one-to-one with calls and an outer
    /// call's token is never taken by an inner one.
    ///
    /// False once this thread already holds `depth` tokens; that call's pop then returns nil.
    mutating func push(_ token: UInt64?, on thread: thread_t) -> Bool {
        var held = byThread.removeValue(forKey: thread) ?? Self.emptyHeld()
        defer { byThread[thread] = held }
        guard held.tokens.count < Self.depth else {
            held.refused += 1
            return false
        }

        held.tokens.append(token)
        return true
    }

    /// An emptied stack stays with its thread: the next push on it allocates nothing.
    mutating func pop(on thread: thread_t) -> UInt64? {
        guard var held = byThread.removeValue(forKey: thread) else {
            return nil
        }

        defer { byThread[thread] = held }
        guard held.refused == 0 else {
            held.refused -= 1
            return nil
        }

        return held.tokens.popLast() ?? nil
    }
}

/// Sleeps until the earliest armed deadline, then walks every callback still inside its call.
final class CallbackWatchdog: @unchecked Sendable {
    private struct State {
        var watch: CallbackWatch = .init()
        var nextToken: UInt64 = 0
        var running = false
    }

    /// Bounds one timed wait: a deadline further out than this is re-read after it.
    private static let longestWaitNanoseconds: UInt64 = 5000000000

    private let name: String
    private let clock: Clock = .init()
    private let walker: ThreadWalker = .init()
    private let guarded: Mutex<State> = .init(State())
    private let wake: DispatchSemaphore = .init(value: 0)
    private var thread: Thread?

    init(name: String) {
        self.name = name
    }

    deinit {
        stop()
    }

    private static func isAlive(_ thread: thread_t) -> Bool {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS
    }

    /// Arms for the calling thread — the one the callback is running on. Nil while stopped.
    func enter(threshold: UInt64) -> UInt64? {
        let now = clock.now().nanoseconds
        let thread = pthread_mach_thread_np(pthread_self())
        let deadline = now &+ threshold
        let armed = guarded.withLock { state -> (token: UInt64, wakes: Bool)? in
            guard state.running else {
                return nil
            }

            let wasIdle = state.watch.isIdle
            let earliest = state.watch.earliestDeadlineNanoseconds ?? .max
            state.nextToken &+= 1
            state.watch.enter(state.nextToken, on: thread, at: now, threshold: threshold)
            return (state.nextToken, wasIdle || deadline < earliest)
        }
        guard let armed else {
            return nil
        }

        if armed.wakes {
            wake.signal()
        }
        return armed.token
    }

    func leave(_ token: UInt64) -> [UInt64]? {
        guarded.withLock { $0.watch.leave(token) }
    }

    func start() {
        guard thread == nil else {
            return
        }

        guarded.withLock { $0.running = true }
        let watching = Thread { [weak self] in
            while !Thread.current.isCancelled {
                guard let wake = self?.wake else {
                    return
                }

                wake.wait()
                while !Thread.current.isCancelled {
                    guard let self else {
                        return
                    }

                    let now = self.clock.now().nanoseconds
                    let (earliest, due) = self.guarded.withLock { state in
                        (state.watch.earliestDeadlineNanoseconds, state.watch.due(at: now))
                    }
                    guard let earliest else {
                        break
                    }
                    guard !due.isEmpty else {
                        let remaining = min(earliest &- now, Self.longestWaitNanoseconds)
                        _ = wake.wait(timeout: .now() + .nanoseconds(Int(remaining)))
                        continue
                    }

                    for armed in due {
                        let frames = self.walkIfAlive(armed.thread)
                        self.guarded.withLock { $0.watch.capture(frames, for: armed.token) }
                    }
                }
            }
        }
        watching.name = name
        // Default QoS is what a stuck callback starves first — this thread has to win that.
        watching.qualityOfService = .userInteractive
        watching.start()
        thread = watching
    }

    func stop() {
        // The counter carries across a stop: a callback still inside its call holds a token that a
        // restarted watchdog would otherwise reissue, and its leave would disarm another's entry.
        guarded.withLock { state in
            let issued = state.nextToken
            state = State()
            state.nextToken = issued
        }
        thread?.cancel()
        thread = nil
        wake.signal()
    }

    /// A callback thread that exited hands its port name to the next thread made.
    private func walkIfAlive(_ thread: thread_t) -> [UInt64] {
        guard Self.isAlive(thread) else {
            return []
        }

        return walker.walk(thread: thread) ?? []
    }
}
