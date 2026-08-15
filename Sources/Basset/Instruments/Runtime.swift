import BassetECS
import Foundation

/// Every thread's stack, as raw return addresses, taken only on a fault.
final class ThreadSnapshot: Faultable, PlainInstrument {
    static let id: InstrumentID = .threadSnapshot
    static let entity = Entity.ID.thread

    private let walker: ThreadWalker = .init()
    private var reportedImages: Set<String> = []

    init() {
        // Captured while the main thread still answers — needed after it stops.
        MainThreadPort.capture()
    }

    /// Count read after the walk, not before — the process can cross the ceiling between the two.
    static func refusal() -> String {
        refusal(liveThreads: ThreadWalker.liveThreadCount())
    }

    static func refusal(
        liveThreads: Int?,
        sanitizerLoaded: Bool = ThreadWalker.isThreadSanitizerLoaded,
        exclusiveHeld: Bool = ThreadWalker.exclusiveIsHeld()
    ) -> String {
        guard !sanitizerLoaded else {
            return "unavailable: a thread sanitizer is loaded"
        }
        guard !exclusiveHeld else {
            return "unavailable: another walk held the lock past its timeout"
        }
        guard let liveThreads else {
            return "unavailable: the thread list could not be read"
        }
        guard liveThreads > ThreadWalker.maxThreads else {
            return "unavailable: the walk reported no threads"
        }

        return "unavailable: \(liveThreads) threads, past the "
            + "\(ThreadWalker.maxThreads) this walk will suspend"
    }

    func fault(_ kind: FaultKind, _ out: inout Readings) {
        take(into: &out)
    }

    /// One entity per thread, not one holding all — a reader can take one without the rest.
    private func take(into out: inout Readings) {
        let stacks = walker.walk()
        guard let first = stacks.first else {
            out.put(.mechanismStatus(Self.refusal()))
            return
        }

        describe(first, into: &out)
        for stack in stacks.dropFirst() {
            out.also(Self.entity) { thread in describe(stack, into: &thread) }
        }
        for image in BinaryImages.covering(stacks.flatMap(\.frames))
            where reportedImages.insert(image.uuid).inserted
        {
            out.also(.binaryImage) { entry in
                entry.put(.imageName(image.name))
                entry.put(.imageLoadAddress(image.loadAddress))
                entry.put(.imageUUID(image.uuid))
            }
        }
    }

    private func describe(_ stack: ThreadStack, into out: inout Readings) {
        out.put(.threadIndex(UInt32(stack.index)))
        out.put(.threadName(stack.name))
        out.put(.threadIsMain(stack.isMain))
        // Innermost first — arrival order is stack order, nothing needs numbering.
        for frame in stack.frames {
            out.put(.frameAddress(frame))
        }
        if stack.truncated {
            out.put(.mechanismStatus("truncated: stack cut at \(ThreadWalker.maxFrames) frames"))
        }
    }
}

/// Main thread work, sampled 20/sec — identical stacks collapse into one reading.
final class StackSamples: Streamable, Configurable {
    struct Config: Codable, Sendable {
        let intervalMs: Int
    }

    /// A reference, not the mutex itself — noncopyable, so a closure can't capture it.
    private final class Samples: @unchecked Sendable {
        private let guarded: Mutex<StackWindow> = .init(.init())

        func record(_ frames: [UInt64]?) {
            guarded.withLock { $0.record(frames) }
        }

        func close() -> StackWindow {
            guarded.withLock { window in
                defer { window = StackWindow() }
                return window
            }
        }
    }

    static let id: InstrumentID = .stackSamples
    static let entity = Entity.ID.stackSample

    /// Bites only when every sample differs — reports as truncation, not a top-8 cutoff.
    static let stacksPerWindow = 8

    /// Fast enough to catch a stall in several samples, slow enough to stay under budget.
    static let defaultConfig: Config = .init(intervalMs: 50)

    /// Below the minimum, sampling burns CPU; above the maximum, a stall hides between samples.
    private static let minimumIntervalMs = 10
    private static let maximumIntervalMs = 1000

    let interval: TimeInterval

    private let walker: ThreadWalker = .init()
    private let samples: Samples = .init()
    private var sampler: Thread?
    private var reportedImages: Set<String> = []

    init(config: Config) {
        let clampedMs = min(max(config.intervalMs, Self.minimumIntervalMs), Self.maximumIntervalMs)
        interval = Double(clampedMs) / 1000
        // Captured while the main thread still answers — before launch identifies it.
        MainThreadPort.capture()
    }

    /// The two reasons need different fixes, so the status says which one it was.
    static func unreadableStatus(
        sanitizerLoaded: Bool = ThreadWalker.isThreadSanitizerLoaded
    ) -> String {
        if sanitizerLoaded {
            "unavailable: a thread sanitizer is loaded"
        } else {
            "unavailable: no main thread has been identified"
        }
    }

    /// Every stack carries the window's totals, so its share is readable without its siblings.
    private static func put(
        _ stack: StackWindow.SampledStack?,
        in closed: StackWindow,
        over elapsed: Context.FlushWindow,
        into out: inout Readings
    ) {
        out.put(.sampleCount(closed.samplesTaken))
        out.put(.unwindFailureCount(closed.withoutStack))
        out.put(.windowNanoseconds(elapsed.nanoseconds))
        out.put(.threadIsMain(true))
        guard let stack else {
            return
        }

        out.put(.occurrenceCount(stack.hits))
        // Innermost first — arrival order is stack order, nothing needs numbering.
        for frame in stack.frames {
            out.put(.frameAddress(frame))
        }
    }

    func write(
        _ closed: StackWindow,
        over elapsed: Context.FlushWindow,
        into out: inout Readings
    ) {
        guard closed.samplesTaken > 0 else {
            guard closed.unreadable > 0 else {
                return
            }

            out.put(.windowNanoseconds(elapsed.nanoseconds))
            out.put(.mechanismStatus(Self.unreadableStatus()))
            return
        }

        let hottest = closed.hottest
        guard let first = hottest.first else {
            // Reported, not dropped — silence here would read as an idle app.
            Self.put(nil, in: closed, over: elapsed, into: &out)
            return
        }

        Self.put(first, in: closed, over: elapsed, into: &out)
        for stack in hottest.dropFirst().prefix(Self.stacksPerWindow - 1) {
            out.also(Self.entity) { sibling in
                Self.put(stack, in: closed, over: elapsed, into: &sibling)
            }
        }

        if hottest.count > Self.stacksPerWindow {
            out.also(Self.entity) { sibling in
                sibling.put(.windowNanoseconds(elapsed.nanoseconds))
                sibling.put(
                    .mechanismStatus("truncated: \(hottest.count - Self.stacksPerWindow) more")
                )
            }
        }

        let reported = hottest.prefix(Self.stacksPerWindow).flatMap(\.frames)
        for image in BinaryImages.covering(reported)
            where reportedImages.insert(image.uuid).inserted
        {
            out.also(.binaryImage) { entry in
                entry.put(.imageName(image.name))
                entry.put(.imageLoadAddress(image.loadAddress))
                entry.put(.imageUUID(image.uuid))
            }
        }
    }

    func observe(_ context: Context) {
        let sampling = Thread { [walker, samples, interval] in
            while !Thread.current.isCancelled {
                Thread.sleep(forTimeInterval: interval)
                guard context.isActive else {
                    continue
                }

                samples.record(walker.walkMainThread())
            }
        }
        sampling.name = QueueLabel.stackSampler
        // Default QoS is what a hang starves first — this thread has to win that contention.
        sampling.qualityOfService = .userInteractive
        sampling.start()
        sampler = sampling

        context.flush(every: .seconds(1)) { [weak self] out, elapsed in
            guard let self else {
                return
            }

            self.write(self.samples.close(), over: elapsed, into: &out)
        }
    }

    func stopObserving() {
        sampler?.cancel()
        sampler = nil
        _ = samples.close()
    }
}

/// One window's samples, identical stacks counted — testable without a real thread.
struct StackWindow {
    struct SampledStack {
        let frames: [UInt64]
        var hits: UInt64
    }

    /// Counted apart from `unreadable`: a quiet app differs from a mechanism not running.
    private(set) var samplesTaken: UInt64 = 0
    private(set) var unreadable: UInt64 = 0
    private(set) var withoutStack: UInt64 = 0

    private var counted: [Int: SampledStack] = [:]

    var hottest: [SampledStack] {
        counted.values.sorted { $0.hits > $1.hits }
    }

    mutating func record(_ frames: [UInt64]?) {
        guard let frames else {
            unreadable += 1
            return
        }

        samplesTaken += 1
        guard !frames.isEmpty else {
            withoutStack += 1
            return
        }

        var hasher = Hasher()
        for frame in frames {
            hasher.combine(frame)
        }

        let key = hasher.finalize()
        if counted[key] != nil {
            counted[key]?.hits += 1
        } else {
            counted[key] = SampledStack(frames: frames, hits: 1)
        }
    }
}

/// What's mapped into the process and what the app shipped; statics are invisible here.
final class LinkedLibraries: Snapshotable, PlainInstrument {
    static let id: InstrumentID = .linkedLibraries
    static let entity = Entity.ID.binaryImage

    /// Past this, an app's finding is in the count, not the list.
    static let ceiling = 64

    init() {}

    static func write(
        _ images: [BinaryImage],
        shippedUnder directory: String,
        into out: inout Readings
    ) {
        guard !images.isEmpty else {
            out.put(.mechanismStatus("unavailable: dyld listed no images"))
            return
        }

        let bundled = images.filter { $0.isShipped(under: directory) }
            .sorted { $0.size > $1.size }
        guard let first = bundled.first else {
            // Nothing but the OS — the answer for an app with no linked dependencies.
            out.put(.occurrenceCount(UInt64(images.count)))
            out.put(.bundledImageCount(0))
            return
        }

        put(first, among: images, bundled: bundled.count, into: &out)
        for image in bundled.dropFirst(1).prefix(ceiling - 1) {
            out.also(Self.entity) { sibling in
                put(image, among: images, bundled: bundled.count, into: &sibling)
            }
        }

        guard bundled.count > ceiling else {
            return
        }

        out.also(Self.entity) { sibling in
            sibling.put(.mechanismStatus("truncated: \(bundled.count - ceiling) more"))
        }
    }

    /// Largest first — the ones worth asking about cost the most to map.
    private static func put(
        _ image: BinaryImage,
        among all: [BinaryImage],
        bundled: Int,
        into out: inout Readings
    ) {
        out.put(.occurrenceCount(UInt64(all.count)))
        out.put(.bundledImageCount(UInt64(bundled)))
        out.put(.imageName(image.name))
        out.put(.imageLoadAddress(image.loadAddress))
        out.put(.imageUUID(image.uuid))
        out.put(.imageTextBytes(image.size))
    }

    func reading(_ out: inout Readings) {
        Self.write(
            BinaryImages.loaded(),
            shippedUnder: BinaryImages.shippedDirectory(),
            into: &out
        )
    }
}

/// Whether a watched method still runs its framework's own code, or was replaced.
final class MethodOwners: Snapshotable, PlainInstrument {
    /// An empty `image` means the address is a runtime-built trampoline, not a failure to look.
    struct Owner: Equatable {
        let className: String
        let selector: String
        let image: String
        let declaringImage: String

        var isInMappedImage: Bool {
            !image.isEmpty
        }

        var isDeclaringImage: Bool {
            !image.isEmpty && image == declaringImage
        }
    }

    static let id: InstrumentID = .methodOwners
    static let entity = Entity.ID.method

    /// Appearance and layout are absent — basset hooks those itself and would self-report.
    static let watched: [(className: String, selector: String)] = [
        ("UIViewController", "viewWillAppear:"),
        ("UIViewController", "viewWillDisappear:"),
        ("UIApplication", "sendEvent:"),
        ("UIControl", "sendAction:to:forEvent:"),
        ("UIWindow", "makeKeyAndVisible"),
        ("NSObject", "forwardInvocation:"),
    ]

    init() {}

    static func write(_ owners: [Owner], into out: inout Readings) {
        guard let first = owners.first else {
            out.put(.mechanismStatus("unavailable: none of the watched classes are loaded"))
            return
        }

        put(first, into: &out)
        for owner in owners.dropFirst() {
            out.also(Self.entity) { sibling in put(owner, into: &sibling) }
        }
    }

    /// A class the process never loaded is absent, not reported as unowned.
    static func read(_ watched: [(className: String, selector: String)]) -> [Owner] {
        watched.compactMap { entry in
            guard let owner = objc_getClass(entry.className) as? AnyClass,
                  let method = class_getInstanceMethod(
                      owner,
                      NSSelectorFromString(entry.selector)
                  )
            else {
                return nil
            }

            return Owner(
                className: entry.className,
                selector: entry.selector,
                image: image(holding: method_getImplementation(method)),
                declaringImage: declaringImage(of: owner)
            )
        }
    }

    /// A watched method resolving here would be reporting basset's own hook, not anyone else's.
    static func ownImage() -> String {
        declaringImage(of: MethodOwners.self)
    }

    private static func image(holding implementation: IMP) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(implementation), &info) != 0,
              let name = info.dli_fname
        else {
            return ""
        }

        return (String(cString: name) as NSString).lastPathComponent
    }

    private static func declaringImage(of owner: AnyClass) -> String {
        guard let name = class_getImageName(owner) else {
            return ""
        }

        return (String(cString: name) as NSString).lastPathComponent
    }

    private static func put(_ owner: Owner, into out: inout Readings) {
        out.put(.methodClass(owner.className))
        out.put(.methodName(owner.selector))
        out.put(.implementationInMappedImage(owner.isInMappedImage))
        out.put(.ownedByDeclaringImage(owner.isDeclaringImage))
        // Absent, not empty — never a blank string to misread as an image.
        guard owner.isInMappedImage else {
            return
        }

        out.put(.imageName(owner.image))
    }

    func reading(_ out: inout Readings) {
        Self.write(Self.read(Self.watched), into: &out)
    }
}
