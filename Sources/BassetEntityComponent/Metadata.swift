import Foundation

/// Which of the three protocols an instrument implements, decided by the factory that accepted it.
public enum Delivery: String, Codable, Sendable {
    case reading
    case stream
    case fault
}

/// Two reasons an instrument may not run here: hardware absent from a simulator, or a newer API.
public struct Availability: Codable, Sendable, Equatable {
    public static let runningMajorVersion = ProcessInfo.processInfo
        .operatingSystemVersion.majorVersion

    public let simulator: Bool
    public let minIOS: Int

    /// Answered per device, not decided when the catalog is built — a fleet spans OS versions.
    public var isSatisfiedHere: Bool {
        // Guarded to iOS: on macOS this would compare minIOS against the Mac's own major version.
        #if os(iOS)
        guard minIOS <= Self.runningMajorVersion else {
            return false
        }

        #endif

        #if targetEnvironment(simulator)
        return simulator
        #else
        return true
        #endif
    }

    public init(simulator: Bool = true, minIOS: Int = 17) {
        self.simulator = simulator
        self.minIOS = minIOS
    }
}

/// Everything about an instrument no device code reads. A value, so it needs no `Instrument`.
public struct InstrumentMetadata: Codable, Sendable, Equatable {
    public enum Mechanism: String, Codable, Sendable {
        case none
        case statusRead
        case notification
        /// An Apple watcher object basset creates and owns (`NWPathMonitor`, `CADisplayLink`)
        /// — a live callback, but on nothing the app itself created or exposed.
        case osWatcher
        case kvo
        case swizzle
        case delegateProxy
        case runLoopObserver
        case machCall
        case osLogStore
        case metricKit
        /// Reading a framework's internals by name (`Mirror`, `object_getIvar`); fails to silence.
        case reflection
    }

    public enum Cadence: String, Codable, Sendable {
        case once
        case onChange
        case interval
    }

    public enum Overhead: String, Codable, Sendable {
        case negligible
        case low
        case medium
        case high
    }

    /// Which runs a reading describes — almost always this one, but MetricKit reports the past.
    public enum Observed: String, Codable, Sendable {
        case thisRun
        case pastRuns
    }

    /// One key a `Configurable` instrument's config JSON accepts — empty for every other one.
    public struct ConfigField: Codable, Sendable, Equatable {
        /// The bound named here is the one instrument's own clamp reads — never a second copy.
        public enum ValueType: Codable, Sendable, Equatable {
            case int(range: ClosedRange<Int>? = nil)
            case double(range: ClosedRange<Double>? = nil)
            case bool
            case string(maxLength: Int? = nil)

            public var rendered: String {
                switch self {
                case .int(let range):
                    range.map { "int \($0)" } ?? "int"
                case .double(let range):
                    range.map { "double \($0)" } ?? "double"
                case .bool:
                    "bool"
                case .string(let maxLength):
                    maxLength.map { "string, \($0) characters max" } ?? "string"
                }
            }

            public var intRange: ClosedRange<Int>? {
                guard case .int(let range) = self else {
                    return nil
                }

                return range
            }

            public var doubleRange: ClosedRange<Double>? {
                guard case .double(let range) = self else {
                    return nil
                }

                return range
            }

            public var stringMaxLength: Int? {
                guard case .string(let maxLength) = self else {
                    return nil
                }

                return maxLength
            }
        }

        public let key: String
        public let type: ValueType
        public let description: String

        public init(key: String, type: ValueType, description: String) {
            self.key = key
            self.type = type
            self.description = description
        }
    }

    public let summary: String
    public let whenToUse: String
    public let reveals: [String]
    public let related: [String]
    public let mechanism: Mechanism
    public let cadence: Cadence
    public let observed: Observed
    public let overhead: Overhead
    public let config: [ConfigField]
    public let minimumSDKVersion: String

    public init(
        summary: String,
        whenToUse: String,
        reveals: [String],
        related: [String],
        mechanism: Mechanism,
        cadence: Cadence,
        observed: Observed = .thisRun,
        overhead: Overhead = .negligible,
        config: [ConfigField] = [],
        minimumSDKVersion: String = "0.1.1"
    ) {
        self.summary = summary
        self.whenToUse = whenToUse
        self.reveals = reveals
        self.related = related
        self.mechanism = mechanism
        self.cadence = cadence
        self.observed = observed
        self.overhead = overhead
        self.config = config
        self.minimumSDKVersion = minimumSDKVersion
    }

    /// Custom only for fields newer than the type: older serialized metadata predates them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        whenToUse = try container.decode(String.self, forKey: .whenToUse)
        reveals = try container.decode([String].self, forKey: .reveals)
        related = try container.decode([String].self, forKey: .related)
        mechanism = try container.decode(Mechanism.self, forKey: .mechanism)
        cadence = try container.decode(Cadence.self, forKey: .cadence)
        observed = try container.decode(Observed.self, forKey: .observed)
        overhead = try container.decode(Overhead.self, forKey: .overhead)
        config = try container.decodeIfPresent([ConfigField].self, forKey: .config) ?? []
        minimumSDKVersion = try container.decodeIfPresent(
            String.self,
            forKey: .minimumSDKVersion
        ) ?? "0.1.1"
    }
}

public extension InstrumentID {
    /// The prose half of the catalog. A switch, so an id added without one is a build error.
    var metadata: InstrumentMetadata {
        switch self {
        case .memoryFootprint:
            InstrumentMetadata(
                summary: "The memory ledger jetsam kills on, and how much of it is left",
                whenToUse: "the app is being killed with no crash report, or memory growth is suspected",
                reveals: [
                    "phys_footprint, the number iOS measures the app against",
                    "how many bytes remain before this app's limit, and what that limit currently is",
                    "whether footprint is growing across a capture, and whether headroom is shrinking with it",
                ],
                related: ["memory.pressure", "lifecycle.lastRunEnded", "device.info"],
                mechanism: .machCall,
                cadence: .once
            )
        case .deviceInfo:
            InstrumentMetadata(
                summary: "Hardware, OS and build identity for the device under capture",
                whenToUse: "read alongside any other instrument whose numbers change meaning between hardware and a simulator, or between build configurations",
                reveals: [
                    "whether a debugger is attached, which suppresses hang detection and makes every timing number in the capture suspect",
                    "which device model and OS produced the rest of the capture",
                    "whether the readings came from a debug build or a simulator",
                    "which version of this SDK produced the capture",
                ],
                related: ["memory.footprint", "power.thermalState"],
                mechanism: .statusRead,
                cadence: .once
            )
        case .thermalState:
            InstrumentMetadata(
                summary: "The thermal pressure level iOS is reporting, and every change to it",
                whenToUse: "performance degrades over time rather than immediately, or when frame rate falls without a code change",
                reveals: [
                    "whether the device was throttling while other instruments were recording",
                    "when thermal pressure crossed into serious or critical",
                ],
                related: ["device.info", "uikit.view.layoutPass"],
                mechanism: .notification,
                cadence: .onChange
            )
        case .cameraSessionState:
            InstrumentMetadata(
                summary: "Whether a capture session is running, and whether iOS interrupted it",
                whenToUse: "the camera preview is black, freezes, or stops after a phone call or a split-screen transition",
                reveals: [
                    "whether the session ever reached running",
                    "whether it was interrupted rather than failing in app code",
                ],
                related: ["device.info", "power.thermalState"],
                mechanism: .kvo,
                cadence: .onChange
            )
        case .viewControllerAppear:
            InstrumentMetadata(
                summary: "Every view controller that finishes appearing, in order",
                whenToUse: "you need to know which screen the user was on when something else went wrong, or to prove a screen was never reached",
                reveals: [
                    "the sequence of screens leading up to a fault",
                    "whether a screen appeared at all",
                ],
                related: ["uikit.view.layoutPass"],
                mechanism: .swizzle,
                cadence: .onChange,
                overhead: .negligible
            )
        case .viewLayoutPass:
            InstrumentMetadata(
                summary: "How many layout passes run each second and how long they take",
                whenToUse: "scrolling stutters, a screen is slow to settle, or layout thrash is suspected",
                reveals: [
                    "layout passes per second, aggregated rather than per call",
                    "total and worst-case time spent inside layoutSubviews",
                ],
                related: ["uikit.viewController.appear", "power.thermalState"],
                mechanism: .swizzle,
                cadence: .interval,
                overhead: .low
            )
        case .urlSessionTaskMetrics:
            InstrumentMetadata(
                summary: "What a URLSession request actually did on the wire",
                whenToUse: "a request is slow, fails only for some users, or the app blames the network and the server disagrees",
                reveals: [
                    "how long the whole transaction took, and the status it came back with",
                    "which protocol was negotiated and whether the connection was reused",
                    "how many body bytes went each way",
                ],
                related: ["device.info", "power.thermalState"],
                mechanism: .delegateProxy,
                cadence: .onChange,
                overhead: .low
            )
        case .networkPathTransitions:
            InstrumentMetadata(
                summary: "Every change to which interface the device is actually using",
                whenToUse: "requests fail or stall while moving — leaving wifi, entering a lift, on a train — or the app behaves differently on cellular",
                reveals: [
                    "when the path moved between wifi, cellular and nothing",
                    "whether the interface was expensive or constrained at the time",
                    "why a path was unsatisfied, including the local-network denial that has no other signal",
                ],
                related: ["network.urlSession.taskMetrics"],
                mechanism: .osWatcher,
                cadence: .onChange
            )
        case .appStateChanges:
            InstrumentMetadata(
                summary: "Whether the app was in front, and how long it was away",
                whenToUse: "read alongside anything else — a capture that goes quiet is either an app that stopped being asked or an app iOS suspended, and only this says which",
                reveals: [
                    "which way the interface is oriented on every reading, so one taken in landscape is not read as a portrait one",
                    "a reading on rotation itself, but only in an app that already asks iOS for device orientation notifications",
                    "when the app went to background and came back",
                    "how long it was away, which is how a gap in a capture is explained rather than guessed at",
                ],
                related: ["device.info"],
                mechanism: .notification,
                cadence: .onChange
            )
        case .cameraDeviceInventory:
            InstrumentMetadata(
                summary: "Every camera the hardware exposes, and every combination it will run at once",
                whenToUse: "a camera configuration that works on one iPhone model produces no preview on another, and the multi-camera set the app asks for may not exist there",
                reveals: [
                    "which capture devices the phone actually has, by type and position",
                    "the full set of camera combinations multi-camera capture supports on it",
                    "whether a requested pairing is absent from the hardware rather than rejected by the app",
                    "how many formats each camera offers, and whether any of them supports multi-camera",
                ],
                related: [
                    "camera.session.configuration", "camera.device.format", "device.info",
                ],
                mechanism: .statusRead,
                cadence: .once
            )
        case .cameraSessionConfiguration:
            InstrumentMetadata(
                summary: "What a capture session is actually holding: inputs, outputs, live connections, and what the hardware charges for them",
                whenToUse: "a camera preview is black while the session reports no error — the inputs or outputs it looks like it has may never have been added, or the hardware cost may be keeping it from starting",
                reveals: [
                    "whether the session is a multi-camera session or an ordinary one",
                    "how many inputs and outputs it holds, against how many the app meant to add",
                    "how many of its connections are both active and enabled, so a configured-but-silent path is visible",
                    "the multi-camera hardware and system-pressure cost, and whether it is over what the session will start at",
                ],
                related: [
                    "camera.session.state", "camera.device.format",
                    "camera.frames.delivery",
                    "camera.device.inventory",
                ],
                mechanism: .kvo,
                cadence: .onChange,
                config: [
                    InstrumentMetadata.ConfigField(
                        key: "callers",
                        type: .bool,
                        description: "Report which of the app's own code built each session, as return addresses into the images from its own bundle. Frames inside the OS are left out: they say nothing about the caller. Default true."
                    ),
                ]
            )
        case .cameraDeviceFormat:
            InstrumentMetadata(
                summary: "The format each camera in a session is running, and whether the output attached to it can carry the pixels that format produces",
                whenToUse: "the same camera code shows a preview on one iPhone model and a black screen on another, where picking the largest or highest-quality format lands on a different format per model",
                reveals: [
                    "the resolution, pixel format and frame-rate range the camera is actually running",
                    "whether the pixel format the video output was told to deliver is one the active format can give it",
                    "the rotation angle and mirroring on the connection feeding the preview",
                    "the colour space, and the system pressure level the camera is under",
                ],
                related: [
                    "camera.frames.delivery", "camera.session.configuration",
                    "camera.device.inventory", "power.thermalState",
                ],
                mechanism: .kvo,
                cadence: .onChange
            )
        case .cameraFrameDelivery:
            InstrumentMetadata(
                summary: "How many camera frames reach the app each second, how long the app's own delegate takes to process each one, how many the system threw away instead, and why",
                whenToUse: "a camera preview is black, frozen, or the app hangs while a session runs — frames may not be arriving at all, may be arriving and being dropped faster than they are consumed, or may be arriving on time while the app's own per-frame processing runs long enough to miss the next one",
                reveals: [
                    "whether any frames reach the app, reported every second including the seconds where none did — but only while a connection is carrying, so zero means a starved camera rather than a stopped one",
                    "wall-clock time the app's own captureOutput:didOutputSampleBuffer:fromConnection: spends per frame, totalled and peak for the window",
                    "which delegate class is receiving frames, reported once when it starts being watched",
                    "how many frames the system dropped, which an app that never wrote a drop callback cannot see",
                    "whether drops are the buffer pool running out, a frame arriving late, or a break in the stream",
                    "counted across every camera in the session together, not per camera",
                ],
                related: [
                    "camera.device.format", "camera.session.configuration",
                    "camera.session.state",
                    "memory.footprint",
                ],
                mechanism: .swizzle,
                cadence: .interval,
                overhead: .low
            )
        case .mainThreadHang:
            InstrumentMetadata(
                summary: "How long the main run loop went without returning to idle",
                whenToUse: "the app freezes, a tap does nothing for a moment, or a screen stops responding",
                reveals: [
                    "how long the main thread stayed busy, and whether it recovered",
                    "whether one long callback or a run of back-to-back ones caused it",
                    "a faultId shared with the thread snapshot this hang triggers, so the two join without guessing from timing",
                ],
                related: [
                    "uikit.view.layoutPass",
                    "memory.footprint",
                    "power.thermalState",
                ],
                mechanism: .runLoopObserver,
                cadence: .onChange,
                overhead: .negligible,
                config: [
                    InstrumentMetadata.ConfigField(
                        key: "thresholdMs",
                        type: .int(range: 100...60000),
                        description: "How long the main thread must stay busy before this reports. Default 2000."
                    ),
                ]
            )
        case .threadSnapshot:
            InstrumentMetadata(
                summary: "Every thread's stack, as addresses the developer's own build can resolve",
                whenToUse: "the app is frozen or slow and the question is what it is actually executing",
                reveals: [
                    "what each thread is doing, innermost frame first",
                    "which thread is main, and what it is waiting on",
                    "the build and load address each address belongs to, so a local dSYM resolves it",
                    "when triggered by a hang or a critical memory crossing, a faultId shared with the reading that triggered it",
                ],
                related: ["concurrency.mainThreadHang", "device.info"],
                mechanism: .machCall,
                cadence: .once,
                overhead: .medium
            )
        case .swiftUIRuntimeIssues:
            InstrumentMetadata(
                summary: "SwiftUI's own runtime issues, read from the unified log inside the process",
                whenToUse: "a SwiftUI screen flickers, updates in a loop, shows stale data, or behaves differently in release than in the debugger",
                reveals: [
                    "whether state was modified during a view update, which is undefined behaviour and the usual cause of a re-render loop",
                    "whether an ObservableObject, AppStorage or published value was mutated from a background thread",
                    "preference and geometry actions updating more than once per frame, and invalid frame dimensions",
                    "how many times each violation happened, rather than one reading per occurrence",
                ],
                related: [
                    "swiftui.host.updates",
                    "swiftui.host.appear",
                    "concurrency.mainThreadHang",
                ],
                mechanism: .osLogStore,
                cadence: .interval,
                overhead: .low
            )
        case .swiftUIHostAppear:
            InstrumentMetadata(
                summary: "Every SwiftUI screen that finishes appearing, with the root view type and how long it took",
                whenToUse: "you need to know which SwiftUI screen the user was on, prove a screen was never reached, or find a screen that is slow to appear",
                reveals: [
                    "the developer's own root view type, with modifier wrappers unwrapped",
                    "whether the type erased itself to AnyView, in which case the navigation title is the only readable name",
                    "how long the hosting controller took from viewDidLoad to viewDidAppear",
                    "how many SwiftUI hosts are alive, which rises when navigation recreates rather than reuses",
                ],
                related: [
                    "swiftui.runtimeIssues",
                    "swiftui.presentation",
                    "uikit.viewController.appear",
                ],
                mechanism: .swizzle,
                cadence: .onChange,
                overhead: .negligible
            )
        case .swiftUIHostUpdates:
            InstrumentMetadata(
                summary: "How often SwiftUI's hosting views lay out, and how long each pass takes",
                whenToUse: "a SwiftUI screen re-renders in a loop, burns CPU or battery while idle, flickers, or scrolls badly",
                reveals: [
                    "update passes per second attributable to SwiftUI alone, rather than to every view in the process",
                    "total and worst-case time inside a SwiftUI layout pass",
                    "whether the app is idle or updating continuously when nothing on screen is changing",
                ],
                related: [
                    "swiftui.runtimeIssues",
                    "uikit.view.layoutPass",
                    "power.thermalState",
                ],
                mechanism: .swizzle,
                cadence: .interval,
                overhead: .low
            )
        case .swiftUIPresentation:
            InstrumentMetadata(
                summary: "SwiftUI sheets and modal screens as they present and dismiss",
                whenToUse: "a sheet does not appear when it should, closes on its own, or the wrong screen is presented",
                reveals: [
                    "whether a presentation happened at all, which a binding-driven sheet otherwise leaves no trace of",
                    "the presentation style UIKit resolved, so a sheet arriving full-screen is visible",
                    "the order of presentations and dismissals, which is where a double-present shows itself",
                ],
                related: ["swiftui.host.appear", "swiftui.runtimeIssues"],
                mechanism: .swizzle,
                cadence: .onChange,
                overhead: .negligible
            )
        case .swiftUIDisplayListChurn:
            InstrumentMetadata(
                summary: "Whether SwiftUI's rendered output is changing, sampled from the hosting view's display list",
                whenToUse: "a screen updates constantly with nothing visibly changing, or you need to separate a re-render loop from ordinary redrawing",
                reveals: [
                    "whether the display list changed at all in each sample — saturating at the sample rate, so read the seed to quantify it",
                    "the seed SwiftUI advances per update, whose rise across readings separates heavy-but-real rendering from a loop that produces nothing",
                    "how many items SwiftUI is rendering — a count near one means the screen draws through UIKit (List and the collection-backed containers) and this instrument has little to say about it",
                    "whether the mechanism reached SwiftUI's renderer at all on this OS version, reported explicitly rather than as an absence",
                ],
                related: ["swiftui.host.updates", "swiftui.runtimeIssues"],
                mechanism: .reflection,
                cadence: .interval,
                overhead: .medium
            )
        case .memoryPressure:
            InstrumentMetadata(
                summary: "When iOS asked for memory back, and what the app was holding at that moment",
                whenToUse: "the app dies with no crash report, drops caches for no visible reason, or gets slower the longer it runs",
                reveals: [
                    "each crossing into warning and critical pressure, and each return to normal",
                    "whether the system was under pressure or this app alone was asked to free memory",
                    "the footprint and remaining headroom at the edge, rather than a sample taken near it",
                    "on a critical crossing, a faultId shared with the thread snapshot it triggers",
                ],
                related: [
                    "memory.footprint",
                    "lifecycle.lastRunEnded",
                    "runtime.threadSnapshot",
                ],
                mechanism: .notification,
                cadence: .onChange
            )
        case .permissionStatus:
            InstrumentMetadata(
                summary: "Every authorization this app can be refused, and whether it is allowed right now",
                whenToUse: "a feature does nothing at all for one user — no error, no callback, no crash — or the app dies the moment a button is tapped",
                reveals: [
                    "the authorization status of every permission-gated framework the app links, in one vocabulary rather than each framework's own",
                    "whether the Info.plist usage description exists, so a request that would terminate the app is visible before it happens",
                    "which frameworks the app does not use at all, by their absence from the reading — except camera and microphone, which basset's own AVFoundation link makes present in every app, and which the usage description distinguishes instead",
                ],
                related: ["permissions.changes", "device.info"],
                mechanism: .statusRead,
                cadence: .once
            )
        case .permissionChanges:
            InstrumentMetadata(
                summary: "Permissions that moved while the app was open, noticed each time it returns to the front",
                whenToUse: "a feature worked earlier in the session and stopped, or the user says they changed something in Settings",
                reveals: [
                    "the full set of statuses once at the start, then only the subjects whose status differs",
                    "when basset noticed a change, which is the app returning to the foreground and not when the user tapped",
                ],
                related: [
                    "permissions.status",
                    "lifecycle.app.state",
                    "lifecycle.lastRunEnded",
                ],
                mechanism: .notification,
                cadence: .onChange
            )
        case .lastRunEnded:
            InstrumentMetadata(
                summary: "Why the previous run stopped, for the deaths that leave no crash report",
                whenToUse: "the app disappears with nothing in the crash reporter, or a user reports it closing itself — activate it at launch, and the next launch explains the death",
                reveals: [
                    "whether the run ended cleanly, was killed for memory, stopped answering long enough for the watchdog, or simply ended with no explanation",
                    "the footprint, remaining headroom and system pressure as of a second before the end, rather than a count of endings",
                    "how long the main thread had gone unresponsive, and how long the run lasted",
                    "which build died, so a count is never read against the wrong one",
                ],
                related: [
                    "memory.pressure",
                    "memory.footprint",
                    "concurrency.mainThreadHang",
                ],
                mechanism: .machCall,
                cadence: .once,
                observed: .pastRuns
            )
        case .threadInventory:
            InstrumentMetadata(
                summary: "Every thread in the process, named and described, without stopping any of them",
                whenToUse: "the app is slow, hot or using more memory than expected and the question is what is running — or how much of it there is",
                reveals: [
                    "how many threads exist, what they are named, and which is main",
                    "what each one is doing right now: running, waiting, or parked by the scheduler as idle",
                    "the CPU each has consumed since it started, and the share it is using now",
                    "the QoS class each thread asked for beside the priority it is actually running at, so a background thread being run at the urgency of whatever is waiting on it — priority donation, the footprint of an inversion — is visible from outside",
                ],
                related: [
                    "cpu.thread.usage",
                    "runtime.threadSnapshot",
                    "concurrency.mainThreadHang",
                ],
                mechanism: .machCall,
                cadence: .once
            )
        case .queueLatency:
            InstrumentMetadata(
                summary: "How long work waits before the main queue runs it",
                whenToUse: "the app feels sluggish or drops frames without ever freezing — the main thread is answering, just late",
                reveals: [
                    "the worst wait a probe block saw in the window, and how many completed",
                    "a main queue that has not run a probe at all since it was submitted, reported as the wait so far rather than as no reading",
                ],
                related: [
                    "concurrency.mainThreadHang",
                    "cpu.thread.usage",
                    "uikit.view.layoutPass",
                ],
                mechanism: .none,
                cadence: .interval
            )
        case .cpuThreadUsage:
            InstrumentMetadata(
                summary: "Which threads are burning CPU right now, and how much of the last window each took",
                whenToUse: "the device is hot, the battery is draining, or the app is slow without being frozen — the question is what is spinning rather than what is stuck",
                reveals: [
                    "CPU nanoseconds consumed per thread over the window just closed, highest first",
                    "the window each count covers, so a rate can be computed rather than assumed",
                    "which thread is main, what it is named, and whether it was running or waiting when sampled",
                ],
                related: [
                    "concurrency.thread.inventory",
                    "cpu.wakeups",
                    "power.thermalState",
                ],
                mechanism: .machCall,
                cadence: .interval,
                overhead: .low,
                config: [
                    InstrumentMetadata.ConfigField(
                        key: "windowSeconds",
                        type: .int(range: 1...30),
                        description: "How often thread CPU usage is sampled and reported. Default 5."
                    ),
                ]
            )
        case .cpuWakeups:
            InstrumentMetadata(
                summary: "How often the process woke the CPU, and how much of that took the package out of idle",
                whenToUse: "the battery drains faster than the CPU time explains, or a backgrounded app is being terminated for resource use",
                reveals: [
                    "wakeups over the window just closed, rather than since the process started — the total the platform enforces its wakeup limit against",
                    "the subset that pulled the platform out of idle, which is the expensive kind and reads zero whenever the device was busy rather than quiet",
                ],
                related: [
                    "cpu.thread.usage",
                    "power.thermalState",
                    "lifecycle.lastRunEnded",
                ],
                mechanism: .machCall,
                cadence: .interval
            )
        case .coreDataSave:
            InstrumentMetadata(
                summary: "Every Core Data save, what it wrote, how long it took, and whether it ran on the right thread",
                whenToUse: "the app stutters when data changes, saves are slow, or Core Data is suspected of being used from the wrong thread",
                reveals: [
                    "inserted, updated and deleted counts per save, so a save writing thousands of rows is visible as one",
                    "how long the save took, measured from the context's own will-save to its did-save",
                    "the context's concurrency type, and a main-queue context saved off the main thread — a certain confinement violation with no false positives",
                ],
                related: [
                    "storage.coreData.changes",
                    "concurrency.mainThreadHang",
                    "cpu.thread.usage",
                ],
                mechanism: .notification,
                cadence: .onChange
            )
        case .coreDataChanges:
            InstrumentMetadata(
                summary: "How much a Core Data stack churns between saves, aggregated per second",
                whenToUse: "a screen stutters while data is on it, an import makes the app unusable, or objects change far more often than the app saves",
                reveals: [
                    "how many change notifications arrived in the window, and how many objects they touched in total",
                    "inserted, updated, deleted and refreshed totals separately, so a refresh storm reads differently from an import",
                    "whether any change in the window came from a main-queue context used off the main thread",
                ],
                related: [
                    "storage.coreData.save",
                    "uikit.view.layoutPass",
                    "cpu.thread.usage",
                ],
                mechanism: .notification,
                cadence: .interval
            )
        case .logFaults:
            InstrumentMetadata(
                summary: "Every error and fault any framework logged inside this process",
                whenToUse: "something is failing and nothing in the app's own code explains it — the framework doing the failing is usually saying so where nobody reads",
                reveals: [
                    "errors and faults from CFNetwork, com.apple.network, CoreData, UIKit and anything else running in the app",
                    "how many times each distinct line repeated in the window, so a storm reads as one finding with a count",
                    "what the ceiling left out, rather than dropping it quietly",
                ],
                related: [
                    "log.subsystems",
                    "swiftui.runtimeIssues",
                    "network.urlSession.taskMetrics",
                ],
                mechanism: .osLogStore,
                cadence: .interval,
                overhead: .medium,
                config: [
                    InstrumentMetadata.ConfigField(
                        key: "subsystem",
                        type: .string(maxLength: 256),
                        description: "Only this subsystem's errors and faults. Default: every subsystem."
                    ),
                ]
            )
        case .logSubsystems:
            InstrumentMetadata(
                summary: "Which frameworks are logging inside this process, and how loudly",
                whenToUse: "before asking for anything else in this domain — it says which subsystems exist to ask about, which no published list does",
                reveals: [
                    "every subsystem and category that logged in the window, ranked by how many of its lines were errors or faults",
                    "how much each one logged, so a storm is visible as volume before its contents are read",
                ],
                related: ["log.faults", "swiftui.runtimeIssues"],
                mechanism: .osLogStore,
                cadence: .interval,
                overhead: .medium,
                config: [
                    InstrumentMetadata.ConfigField(
                        key: "subsystem",
                        type: .string(maxLength: 256),
                        description: "Only this subsystem's traffic. Default: every subsystem."
                    ),
                ]
            )
        case .sessionConfiguration:
            InstrumentMetadata(
                summary: "What each URLSession is permitted to do, which its requests never say",
                whenToUse: "requests fail or hang for one user and not others — especially on cellular, on a hotspot, or in Low Data Mode",
                reveals: [
                    "whether the session is allowed on cellular, expensive or constrained networks, which is the commonest cause of a failure only one user sees",
                    "the request and resource timeouts, so a request that never finishes is separated from one that never fails",
                    "whether the session waits for connectivity, which turns a hung request into a patient one",
                    "the cache policy, connection limit, and a TLS floor the app raised above the default",
                ],
                related: [
                    "network.urlSession.taskMetrics",
                    "network.transportSecurity",
                    "network.path.transitions",
                ],
                mechanism: .swizzle,
                cadence: .onChange
            )
        case .transportSecurity:
            InstrumentMetadata(
                summary: "What this build's App Transport Security will and will not load",
                whenToUse: "a URL fails only in the shipped build, or a request to one host fails with a generic error while every other host works",
                reveals: [
                    "whether the app allows arbitrary loads at all, and any blanket exemption for web content, media or local networking",
                    "every exception domain the build ships, and which of them permit plain http",
                    "a per-domain TLS floor, which is how one host fails while the rest are fine",
                ],
                related: [
                    "network.session.configuration",
                    "network.urlSession.taskMetrics",
                ],
                mechanism: .statusRead,
                cadence: .once
            )
        case .framePacing:
            InstrumentMetadata(
                summary: "Whether each frame finished inside the budget the system set for it",
                whenToUse: "scrolling stutters, an animation is not smooth, or the app feels heavy while the main thread is never actually blocked",
                reveals: [
                    "how many frames the app produced in the window, and how many missed the system's own completion deadline",
                    "the worst overrun, measured against the deadline the system gave rather than an assumed refresh interval",
                    "time spent in the Core Animation commit, total and worst, which is the part the app's own layout and drawing pays for",
                    "how far ahead the system expected to present, which is the latency between deciding a frame and showing it",
                ],
                related: [
                    "uikit.view.layoutPass",
                    "swiftui.host.updates",
                    "cpu.thread.usage",
                ],
                mechanism: .osWatcher,
                cadence: .interval,
                overhead: .low
            )
        case .accessibilitySettings:
            InstrumentMetadata(
                summary: "Which accessibility settings this user has turned on, and any they change while the app is open",
                whenToUse: "one user sees behaviour nobody can reproduce — animations that do not run, layouts that overflow, a screen that behaves differently only for them",
                reveals: [
                    "every accessibility setting that is on, by name, out of the twenty the app is expected to adapt to",
                    "Reduce Motion in particular, which makes UIView animations run with no duration and changes when completion handlers fire",
                    "a setting the user changed mid-session, which is when a working screen starts misbehaving without a new build",
                ],
                related: [
                    "environment.dynamicType",
                    "uikit.view.layoutPass",
                    "swiftui.host.updates",
                ],
                mechanism: .notification,
                cadence: .onChange
            )
        case .dynamicType:
            InstrumentMetadata(
                summary: "The text size this user reads at, and whether it is an accessibility size",
                whenToUse: "a layout overflows, clips or overlaps for one user, or text is reported as the wrong size",
                reveals: [
                    "the Dynamic Type category in effect, and every change to it while the app is open",
                    "whether the user is in one of the five accessibility sizes, which is the boundary where layouts written against the normal range stop fitting",
                ],
                related: ["environment.accessibility", "uikit.view.layoutPass"],
                mechanism: .notification,
                cadence: .onChange
            )
        case .localeSettings:
            InstrumentMetadata(
                summary: "The language, region and calendar this device is set to",
                whenToUse: "a failure reproduces for users in one place and nowhere else, a layout appears mirrored, or a date or number is parsed or formatted wrongly",
                reveals: [
                    "the language and region codes in effect, which is what a region-specific crash is keyed on",
                    "whether the language lays out right-to-left, the setting most likely to break a layout nobody tested against it",
                    "the calendar, measurement system and whether the user set 24-hour time, each of which changes what a date or number formatter produces",
                ],
                related: ["environment.dynamicType", "device.info"],
                mechanism: .statusRead,
                cadence: .once
            )
        case .notificationSettings:
            InstrumentMetadata(
                summary: "What the user left switched on for notifications, which being authorized does not say",
                whenToUse: "a user reports never seeing notifications the app believes it delivered, or sees them only somewhere unexpected",
                reveals: [
                    "the authorization status, including provisional and ephemeral, which behave unlike a plain yes",
                    "every way of showing a notification the user has switched off — banners, sounds, badges, lock screen, Scheduled Delivery — while the app remains authorized",
                    "whether previews are hidden, which makes a notification arrive with none of its content",
                    "settings the device does not support at all, kept distinct from ones the user turned off",
                ],
                related: ["permissions.status", "lifecycle.app.state"],
                mechanism: .statusRead,
                cadence: .once
            )
        case .locationSilence:
            InstrumentMetadata(
                summary: "Whether location updates ever arrive after the app asks for them",
                whenToUse: "a feature that needs the user's location never starts, with no error and no crash — the classic silent failure of this framework",
                reveals: [
                    "whether the app's delegate implements the update callback at all, which is the commonest cause and is invisible from inside the app",
                    "how long the app waited between asking for updates and the first one arriving",
                    "how many updates followed, so a delegate that answered once and stopped is separable from one that never answered",
                    "the accuracy class the app asked for, since a coarse one waits far longer for a fix",
                ],
                related: ["permissions.status", "network.path.transitions"],
                mechanism: .swizzle,
                cadence: .onChange
            )
        case .bluetoothCentralState:
            InstrumentMetadata(
                summary: "Why Bluetooth is doing nothing for this user, which looks identical to no device being nearby",
                whenToUse: "an accessory never connects and never errors — before assuming the accessory, since powered off, unauthorized and unsupported all look the same from inside the app",
                reveals: [
                    "the central manager's state each time it changes, including unauthorized, which is a permission denied long ago on a screen nobody remembers",
                    "whether the app's delegate implements the state callback the protocol requires",
                    "nothing whatsoever about any peripheral — a service UUID is a device category, and that is health data",
                ],
                related: ["permissions.status", "location.delegate.silence"],
                mechanism: .swizzle,
                cadence: .onChange
            )
        case .webContentTermination:
            InstrumentMetadata(
                summary: "A web view that went white because its content process died",
                whenToUse: "a screen backed by a web view shows nothing, with no error and no crash, and reloading fixes it",
                reveals: [
                    "each time WebKit's content process died under a web view, which the app is otherwise unaware of",
                    "whether the app handles the callback at all — most do not know it exists, and an app that ignores it leaves a white rectangle on screen",
                    "the page it happened on, redacted to scheme, host and shape",
                ],
                related: ["memory.pressure", "network.path.transitions"],
                mechanism: .swizzle,
                cadence: .onChange
            )
        case .mapTileLoading:
            InstrumentMetadata(
                summary: "A map that came up blank or grey, and the error MapKit reported for it",
                whenToUse: "a map shows a grey grid or stays empty, with nothing in the app's own code to explain it",
                reveals: [
                    "how many times the map finished loading against how many times it failed, which separates a broken map from one nobody panned",
                    "the MKError behind a failure, which is otherwise delivered to a callback almost no app implements",
                    "whether the app was listening for load failures at all",
                ],
                related: ["network.path.transitions", "location.delegate.silence"],
                mechanism: .swizzle,
                cadence: .onChange
            )
        case .callProviderActions:
            InstrumentMetadata(
                summary: "What CallKit asked the app to do, and whether the call ever got audio",
                whenToUse: "a call connects with no audio, ends by itself, or the app's own call UI disagrees with the system's",
                reveals: [
                    "each answer, end, hold and mute CallKit asked the app to perform",
                    "whether CallKit activated the audio session, which is the seam behind no-audio-after-answering and belongs to the audio domain to explain",
                    "which of the watched actions the app's provider delegate handles at all",
                ],
                related: ["permissions.status", "lifecycle.app.state"],
                mechanism: .swizzle,
                cadence: .onChange
            )
        case .audioRoute:
            InstrumentMetadata(
                summary: "Which output the app's audio is coming out of, which microphone is listening, and what put them there",
                whenToUse: "sound comes from the earpiece instead of the speaker, is quiet or narrowband, disappears when a headset is unplugged, plays somewhere the user did not choose, or a recording comes back silent",
                reveals: [
                    "the output port carrying audio right now, and whether that is the earpiece — the play-and-record category routes there by default, and an app that never asked for the speaker is audible only against the ear",
                    "whether the speaker default is set, which survives route changes and interruptions, against a temporary override, which the next route change discards",
                    "the category, mode and every category option in force, including the two that decide whether a Bluetooth accessory can take the route",
                    "each route change with the reason the system gave and the port it moved from",
                    "the output volume, and whether another app's audio is playing or asking for this app's to be silenced",
                    "which microphone is listening, down to the element on it — bottom, front or back — and the pattern it is picking up with",
                    "whether the category admits input at all, which decides the microphone before any hardware or permission does and is the usual answer to a recording that came back silent",
                    "whether the input the app asked for is the one it got, and how many others were available to choose",
                ],
                related: [
                    "call.provider.actions",
                    "permissions.status",
                    "bluetooth.central.state",
                ],
                mechanism: .notification,
                cadence: .onChange
            )
        case .stackSamples:
            InstrumentMetadata(
                summary: "Where the main thread spends its time, sampled and counted rather than caught once",
                whenToUse: "a screen is slow, janky or unresponsive and the question is which code is running, not merely that something is",
                reveals: [
                    "the main thread's stack twenty times a second, with identical stacks counted rather than repeated",
                    "how many samples each stack accounted for out of the samples taken, which is the share of the second that stack was executing",
                    "the build and load address each address belongs to, so a local dSYM resolves it",
                    "how many samples produced no stack at all, so a quiet reading is distinguishable from an idle one",
                ],
                related: [
                    "runtime.threadSnapshot",
                    "concurrency.mainThreadHang",
                    "cpu.thread.usage",
                    "uikit.viewController.appear",
                ],
                mechanism: .machCall,
                cadence: .interval,
                overhead: .medium,
                config: [
                    InstrumentMetadata.ConfigField(
                        key: "intervalMs",
                        type: .int(range: 10...1000),
                        description: "How often the main thread's stack is sampled. Default 50."
                    ),
                ]
            )
        case .imagingRenderPasses:
            InstrumentMetadata(
                summary: "Core Image renders into a Metal texture, and the images built back out of one",
                whenToUse: "an image processed through Core Image comes out rotated or mirrored, and the preview looks nothing like what gets saved",
                reveals: [
                    "how many Core Image renders draw into a Metal texture each second",
                    "how many images the app built from a Metal texture, which is the other half of a round trip",
                    "a round trip flips the image, so the two counts together say whether an output ends up upright",
                    "when a hook the runtime refused leaves a count unmeasured rather than zero",
                ],
                related: [
                    "metal.drawable.presentation",
                    "metal.gpu.latency",
                    "render.frame.pacing",
                    "camera.frames.delivery",
                ],
                mechanism: .swizzle,
                cadence: .interval,
                overhead: .low,
                minimumSDKVersion: "0.8.0"
            )
        case .metalDrawablePresentation:
            InstrumentMetadata(
                summary: "Frames a Metal layer actually put on screen, and the gaps between them",
                whenToUse: "a Metal, SceneKit, RealityKit or game-engine view stutters, and the question is whether frames are reaching the display at all",
                reveals: [
                    "the interval between one frame being shown and the next, measured where the system presented them rather than where the app finished drawing",
                    "frames that were drawn and then skipped, which the system reports as a presentation time of zero",
                    "drawables the app asked for and did not get, which is the layer's pool running dry",
                    "drawables acquired and never presented, from the difference between what was asked for and what came back",
                ],
                related: [
                    "render.frame.pacing",
                    "runtime.stackSamples",
                    "cpu.thread.usage",
                ],
                mechanism: .swizzle,
                cadence: .interval,
                overhead: .low
            )
        case .metalGPULatency:
            InstrumentMetadata(
                summary: "How long the GPU takes to answer a trivial piece of work, as a measure of what it is already carrying",
                whenToUse: "frames are being missed and the question is whether the GPU is the bottleneck, rather than the app's own drawing",
                reveals: [
                    "how long a submission waits before the GPU starts it, which is what rises as the GPU falls behind",
                    "how long the same trivial work takes once started, which is what rises as the device throttles",
                    "how many probes took longer than a frame's budget, and the budget they were judged against",
                    "nothing at all when the app has not drawn through Metal, because no device is created to ask",
                ],
                related: [
                    "metal.drawable.presentation",
                    "render.frame.pacing",
                    "power.thermalState",
                ],
                mechanism: .swizzle,
                cadence: .interval,
                overhead: .medium
            )
        case .linkedLibraries:
            InstrumentMetadata(
                summary: "Every image mapped into this process, and which of them came from the app bundle rather than the OS",
                whenToUse: "launch is slow, the binary is larger than anyone expects, or two dependencies are suspected of fighting over the same behaviour",
                reveals: [
                    "how many images the process maps in total, against how many of them came inside the app",
                    "the shipped images by name, build UUID and code size, largest first, capped at sixty-four with the remainder reported as a count",
                    "nothing about statically-linked packages, whose code merges into the app's own binary and leaves no image to find",
                ],
                related: ["device.info", "runtime.stackSamples", "lifecycle.app.state"],
                mechanism: .statusRead,
                cadence: .once
            )
        case .methodOwners:
            InstrumentMetadata(
                summary: "Whether a watched method still runs the code its framework shipped, or something replaced it while the process was running",
                whenToUse: "behaviour changes between builds or launches for no reason in the app's own code, or two dependencies are suspected of replacing the same method",
                reveals: [
                    "whether each watched method's implementation belongs to any mapped image at all — one that does not was built by the runtime, which is what replacing a method leaves behind",
                    "the image holding it when there is one, named from the address rather than from any list of libraries, and whether that is the image the class itself came from",
                    "that something replaced the method far more often than which library did, because a replacement made through a runtime-built trampoline carries no image to name",
                    "nothing about methods basset hooks itself, which are left out so the reading is never basset's own replacement",
                ],
                related: ["runtime.linkedLibraries", "device.info", "runtime.stackSamples"],
                mechanism: .reflection,
                cadence: .once
            )
        case .windowTouches:
            InstrumentMetadata(
                summary: "Every touch the app's windows received, when each one began and ended, and how far the drags between them travelled",
                whenToUse: "taps do not register, a control is dead in one region of the screen, a scroll steals a tap, or a gesture is suspected of never arriving",
                reveals: [
                    "each touch beginning, ending and being cancelled as its own reading, timestamped, so a touch can be placed against the hang or the save that followed it",
                    "how many fingers were down at that instant, which is the only way a multi-touch gesture can be told from a sequence of taps",
                    "a cancelled touch, which is what a scroll view stealing a tap looks like from the outside and the usual reason a button appears not to work",
                    "drag movement as a per-second total rather than as a reading per movement, because a drag delivers those by the hundred and no capture is worth spending on them",
                    "each touch's own location, and an id shared with the hierarchy reading `hierarchy` pairs with it, so the two can be found again together",
                    "every view under it, only when `hierarchy` is set, and only for the touch that began — not for every touch, and not for a gesture that recognizes without one",
                ],
                related: [
                    "uikit.viewController.appear",
                    "concurrency.mainThreadHang",
                    "render.frame.pacing",
                    "uikit.view.hierarchy",
                    "uikit.control.action",
                    "uikit.gesture.state",
                ],
                mechanism: .swizzle,
                cadence: .interval,
                overhead: .low,
                config: [
                    InstrumentMetadata.ConfigField(
                        key: "hierarchy",
                        type: .bool,
                        description: "Walk the view hierarchy at a touch's own location the " +
                            "instant it begins, and attach it to that touch's reading by a " +
                            "shared id. Off by default — this is the O(views) walk `uikit." +
                            "view.hierarchy`'s own metadata explains, paid on `.began` only, " +
                            "not on every touch."
                    ),
                ]
            )
        case .controlAction:
            InstrumentMetadata(
                summary: "Every control action UIKit sent, and which class received it",
                whenToUse: "a button appears to do nothing, or the question is whether a tap ever reached a target's action method at all",
                reveals: [
                    "the action selector UIKit sent and the class of the object it was sent to, for every control event in the app",
                    "UIKit's own internal actions on a control, not only the app's own — a UIButton sends itself selectors like _buttonDown: and _buttonUp: through this same funnel for its highlight state, so an app's own action is one reading among several rather than the only one",
                    "nothing when the target is nil, which is a control configured with no handler rather than a failure to observe one",
                    "nothing about the touch that led to it — pair with uikit.window.touches for where and when",
                ],
                related: [
                    "uikit.window.touches",
                    "uikit.gesture.state",
                    "runtime.methodOwners",
                ],
                mechanism: .swizzle,
                cadence: .onChange,
                overhead: .negligible,
                minimumSDKVersion: "0.4.0"
            )
        case .gestureState:
            InstrumentMetadata(
                summary: "Every gesture recognizer's state transition, and which class it belongs to",
                whenToUse: "a gesture is suspected of never recognizing, or the question is whether a pan, tap or swipe recognizer ever began at all",
                reveals: [
                    "each state a gesture recognizer transitioned through — possible, began, changed, ended, cancelled, failed — and the recognizer's own class",
                    "a recognizer that enters .began and then .cancelled, which is what another recognizer or a scroll view winning the gesture looks like from here",
                    "every gesture recognizer that transitions, including ones the app never added — UIKit attaches its own to ordinary views for system interactions, and a reading naming one of those is not a bug in the app being read",
                    "nothing if this build's UIKit ever removes the underlying selector: the hook is on `setState:`, which UIKit does not declare in its public header, and the install fails soft rather than crashing when it can't find it",
                ],
                related: [
                    "uikit.window.touches",
                    "uikit.control.action",
                ],
                mechanism: .swizzle,
                cadence: .onChange,
                overhead: .negligible,
                minimumSDKVersion: "0.4.0"
            )
        case .viewHierarchy:
            InstrumentMetadata(
                summary: "Every view whose bounds contain a point, topmost first, with its class and frame",
                whenToUse: "a tap looks like it landed on the wrong view, or the layout at a point needs confirming without a screenshot",
                reveals: [
                    "every view at the point, front to back, named by its own class and its frame in the key window's coordinate space — not the one view a real hit-test would pick",
                    "views a real hit-test would skip: interaction disabled, or a decorative layer stacked on top of a real control — since those are exactly the overlaps this instrument exists to catch",
                    "the same coordinate space uikit.window.touches reports a touch's location in, so a touch's own reading supplies the point directly",
                    "nothing about a window other than the key window, and nothing continuously — this is one walk per request, not a hook",
                ],
                related: [
                    "uikit.window.touches",
                    "uikit.viewController.appear",
                ],
                mechanism: .statusRead,
                cadence: .once,
                config: [
                    InstrumentMetadata.ConfigField(
                        key: "x",
                        type: .double(),
                        description: "The point's x coordinate, in the key window's own " +
                            "coordinate space. Default 0."
                    ),
                    InstrumentMetadata.ConfigField(
                        key: "y",
                        type: .double(),
                        description: "The point's y coordinate, in the key window's own " +
                            "coordinate space. Default 0."
                    ),
                ],
                minimumSDKVersion: "0.4.0"
            )
        case .instrumentsActive:
            InstrumentMetadata(
                summary: "Which instruments this capture is running, restated whenever that set changes",
                whenToUse: "read alongside anything else: a gap in one instrument's readings means it was quiet only if it was running at the time",
                reveals: [
                    "every instrument this request is running after a change, each named by its own id",
                    "the seam a change makes, so readings either side of it are not read as one set",
                    "nothing at all in a capture whose instruments never changed, which is most of them",
                ],
                related: ["basset.configRefused", "device.info"],
                mechanism: .none,
                cadence: .onChange,
                minimumSDKVersion: "0.8.0"
            )
        case .configRefused:
            InstrumentMetadata(
                summary: "basset reporting on itself: a request named config for an instrument this build could not read",
                whenToUse: "a request that set config for an instrument behaves as if the config were never sent",
                reveals: [
                    "which instrument's config this build fell back to its own default for",
                ],
                related: [],
                mechanism: .none,
                cadence: .onChange,
                minimumSDKVersion: "0.2.0"
            )
        case .instrumentsRelevant:
            InstrumentMetadata(
                summary: "basset reporting on itself: which instruments this device believes are worth activating right now",
                whenToUse: "before building a request, to narrow which instruments to name instead of guessing across the whole catalog",
                reveals: [
                    "every instrument whose own runtime probe found something to observe on this device, named by its own id",
                    "nothing about an instrument that always answers relevant, like a hang or memory reading — it is in the list on every device",
                ],
                related: ["basset.instrumentsActive", "device.info"],
                mechanism: .none,
                cadence: .once,
                minimumSDKVersion: "0.8.0"
            )
        }
    }
}
