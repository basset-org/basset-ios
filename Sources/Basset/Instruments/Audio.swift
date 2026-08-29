import BassetEntityComponent
import Foundation

#if os(iOS)
import ObjectiveC
#endif

/// Output port collapsed to the cases routing treats differently; raw port type sits beside it.
enum AudioOutputKind: String, Sendable {
    case receiver
    case speaker
    case handsFree
    case accessory
    case none
}

/// Facts abstracted from `AVAudioSession` so the routing rules below are testable without one.
struct AudioRouteFacts: Sendable {
    let output: AudioOutputKind
    /// The category is play-and-record, the only one that routes to the earpiece.
    let recordsAndPlays: Bool
    /// Kept separate from `defaultToSpeaker`: category options don't reflect what the mode implied.
    let modeImpliesSpeaker: Bool
    /// The option, which is what the caller passed, and nothing more.
    let defaultToSpeaker: Bool

    var speakerRequested: Bool {
        defaultToSpeaker || modeImpliesSpeaker
    }
}

/// What a caller is told about the route. Every case is a state a user can hear.
enum AudioRouteVerdict: String, Sendable {
    /// Earpiece with no speaker request — audible only when the phone is held to the ear.
    case earpieceAndSpeakerDefaultUnset
    /// Earpiece despite a speaker default set — something else is deciding the route.
    case earpieceDespiteSpeakerDefault
    /// Speaker via `overrideOutputAudioPort` only — unplugging a headset drops back to earpiece.
    case speakerHeldByTemporaryOverride
    case speaker
    /// Bluetooth hands-free route: call-grade channel both ways, so music sounds narrowband.
    case handsFreeProfile
    case accessory
    /// The route names no output at all: nothing the app plays is heard.
    case noOutputRoute
}

enum AudioRouting {
    static func verdict(_ facts: AudioRouteFacts) -> AudioRouteVerdict {
        switch facts.output {
        case .none:
            return .noOutputRoute
        case .receiver:
            return facts.speakerRequested
                ? .earpieceDespiteSpeakerDefault
                : .earpieceAndSpeakerDefaultUnset
        case .speaker:
            let placed = facts.recordsAndPlays && !facts.speakerRequested
            return placed ? .speakerHeldByTemporaryOverride : .speaker
        case .handsFree:
            return .handsFreeProfile
        case .accessory:
            return .accessory
        }
    }
}

/// Input port collapsed to the cases the rules treat differently; raw port type sits beside it.
enum AudioInputKind: String, Sendable {
    case builtIn
    case wiredHeadset
    case handsFree
    case accessory
    case none
}

/// The state of the session that decides whether anything is listening.
struct AudioInputFacts: Sendable {
    let input: AudioInputKind
    /// Only these categories admit input; every other leaves the route without one.
    let categoryTakesInput: Bool
}

/// What a caller is told about the microphone: a state a listener can hear, or fail to.
enum AudioInputVerdict: String, Sendable {
    /// No input however many microphones are attached — the case no permission check finds.
    case categoryTakesNoInput
    /// The category records and the route still names no input.
    case noInputRoute
    case builtInMicrophone
    case wiredHeadsetMicrophone
    /// Bluetooth hands-free mic: choosing it also narrows output to the same call-grade profile.
    case handsFreeMicrophone
    case accessoryMicrophone
}

extension AudioRouting {
    static func inputVerdict(_ facts: AudioInputFacts) -> AudioInputVerdict {
        guard facts.categoryTakesInput else {
            return .categoryTakesNoInput
        }

        switch facts.input {
        case .none: return .noInputRoute
        case .builtIn: return .builtInMicrophone
        case .wiredHeadset: return .wiredHeadsetMicrophone
        case .handsFree: return .handsFreeMicrophone
        case .accessory: return .accessoryMicrophone
        }
    }
}

/// Table, not bit tests in order: interrupt-spoken-audio's mask contains mix-with-others' bits.
struct AudioCategoryOptionNames {
    let known: [(mask: UInt, name: String)]

    /// Joined names, or `"none"` — distinguishes no options set from options never read.
    func rendered(_ raw: UInt) -> String {
        let found = names(raw)
        return found.isEmpty ? "none" : found.joined(separator: ",")
    }

    func names(_ raw: UInt) -> [String] {
        var remaining = raw
        var found = [String]()

        for option in known
            .sorted(by: { $0.mask.nonzeroBitCount > $1.mask.nonzeroBitCount })
        {
            guard option.mask != 0, remaining & option.mask == option.mask else {
                continue
            }

            found.append(option.name)
            remaining &= ~option.mask
        }

        found.sort()
        if remaining != 0 {
            // Hex rather than dropped, so a newer OS's option is visible, not silently unnamed.
            found.append("unknown(0x\(String(remaining, radix: 16)))")
        }
        return found
    }
}

final class AudioRoute: Streamable, PlainInstrument {
    static let id: InstrumentID = .audioRoute

    private var observer: NSObjectProtocol?

    init() {}

    #if os(iOS)
    /// A zero-argument class method (`sharedInstance`) isn't `NSObject.perform`'s shape —
    /// same low-level ObjC-runtime call `PermissionProbe` uses to reach a class method
    /// without linking the framework that declares it.
    private static func sharedInstance(_ sessionClass: AnyClass) -> AnyObject? {
        let selector = Selector(("sharedInstance"))
        guard let method = class_getClassMethod(sessionClass, selector) else {
            return nil
        }

        typealias Call = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let implementation = method_getImplementation(method)
        return unsafeBitCast(implementation, to: Call.self)(sessionClass, selector)?
            .takeUnretainedValue()
    }

    /// Never sets category, mode, override or active state — it cannot be the reason audio moved.
    private func report(
        _ session: AnyObject,
        reason: String,
        previousOutput: String?,
        into context: Context
    ) {
        let route = session.value(forKey: "currentRoute") as AnyObject
        let outputs = route.value(forKey: "outputs") as? [AnyObject] ?? []
        let inputs = route.value(forKey: "inputs") as? [AnyObject] ?? []
        let output = outputs.first
        let input = inputs.first
        let optionsRaw = (session.value(forKey: "categoryOptions") as? NSNumber)?.uintValue ?? 0
        let category = session.value(forKey: "category") as? String ?? ""
        let mode = session.value(forKey: "mode") as? String ?? ""
        let outputPort = output?.value(forKey: "portType") as? String
        let inputPort = input?.value(forKey: "portType") as? String

        let inputFacts = AudioInputFacts(
            input: Self.inputKind(of: inputPort),
            categoryTakesInput: Self.admitsInput(category)
        )
        let facts = AudioRouteFacts(
            output: Self.kind(of: outputPort),
            recordsAndPlays: category == "AVAudioSessionCategoryPlayAndRecord",
            modeImpliesSpeaker: mode == "AVAudioSessionModeVideoChat",
            defaultToSpeaker: optionsRaw & 0x8 == 0x8
        )

        context.emit(.audioRoute) { out in
            out.put(.changeReason(reason))
            out.put(.audioRouteVerdict(AudioRouting.verdict(facts).rawValue))
            out.put(.audioInputVerdict(AudioRouting.inputVerdict(inputFacts).rawValue))
            out.put(.audioCategory(category))
            out.put(.audioMode(mode))
            out.put(.audioCategoryOptions(Self.optionNames.rendered(optionsRaw)))
            if let volume = session.value(forKey: "outputVolume") as? Float {
                out.put(.outputVolume(volume))
            }
            if let otherAudioPlaying = session.value(forKey: "isOtherAudioPlaying") as? Bool {
                out.put(.otherAudioPlaying(otherAudioPlaying))
            }
            if let secondarySilenced = session
                .value(forKey: "secondaryAudioShouldBeSilencedHint") as? Bool
            {
                out.put(.secondaryAudioSilenced(secondarySilenced))
            }

            if let outputPort {
                out.put(.audioOutputPort(outputPort))
                if let name = Self.reportableName(of: output, portType: outputPort) {
                    out.put(.audioOutputName(name))
                }
            }
            out.put(.audioOutputCount(UInt32(outputs.count)))
            if let inputAvailable = session.value(forKey: "isInputAvailable") as? Bool {
                out.put(.audioInputAvailable(inputAvailable))
            }

            if let available = session.value(forKey: "availableInputs") as? [AnyObject] {
                out.put(.availableInputCount(UInt32(available.count)))
            }
            if let preferred = session.value(forKey: "preferredInput") as AnyObject?,
               let preferredUID = preferred.value(forKey: "UID") as? String
            {
                let inputUID = input?.value(forKey: "UID") as? String
                out.put(.audioPreferredInputHonored(preferredUID == inputUID))
            }
            if let input, let inputPort {
                out.put(.audioInputPort(inputPort))
                if Self.namesAreTheSystemsOwn(inputPort) {
                    if let name = input.value(forKey: "portName") as? String {
                        out.put(.audioInputName(name))
                    }
                    if let source = input.value(forKey: "selectedDataSource") as AnyObject?,
                       let sourceName = source.value(forKey: "dataSourceName") as? String
                    {
                        out.put(.audioInputDataSource(sourceName))
                        if let pattern = source.value(forKey: "selectedPolarPattern") as? String {
                            out.put(.audioInputPolarPattern(pattern))
                        }
                        if let orientation = source.value(forKey: "orientation") as? String {
                            out.put(.audioInputOrientation(orientation))
                        }
                    }
                }
            }
            if let previousOutput {
                out.put(.audioPreviousOutputPort(previousOutput))
            }
        }
    }

    /// Only built-in/wired port names are reported — an accessory's name is often a person's own.
    private static func reportableName(of port: AnyObject?, portType: String) -> String? {
        guard namesAreTheSystemsOwn(portType) else {
            return nil
        }

        return port?.value(forKey: "portName") as? String
    }

    private static func namesAreTheSystemsOwn(_ portType: String) -> Bool {
        [
            "MicrophoneBuiltIn",
            "Receiver",
            "Speaker",
            "Headphones",
            "MicrophoneWired",
            "LineIn",
            "LineOut",
        ].contains(portType)
    }

    private static func kind(of portType: String?) -> AudioOutputKind {
        switch portType {
        case "Receiver": .receiver
        case "Speaker": .speaker
        case "BluetoothHFP": .handsFree
        case nil: .none
        default: .accessory
        }
    }

    /// The three categories that admit input; every other leaves the route without a microphone.
    static func admitsInput(_ category: String) -> Bool {
        category == "AVAudioSessionCategoryRecord"
            || category == "AVAudioSessionCategoryPlayAndRecord"
            || category == "AVAudioSessionCategoryMultiRoute"
    }

    private static func inputKind(of portType: String?) -> AudioInputKind {
        switch portType {
        case "MicrophoneBuiltIn": .builtIn
        case "MicrophoneWired": .wiredHeadset
        case "BluetoothHFP": .handsFree
        case nil: .none
        default: .accessory
        }
    }

    private static func named(_ reason: UInt?) -> String {
        switch reason {
        case 1: "newDeviceAvailable"
        case 2: "oldDeviceUnavailable"
        case 3: "categoryChange"
        case 4: "override"
        case 6: "wakeFromSleep"
        case 7: "noSuitableRouteForCategory"
        case 8: "routeConfigurationChange"
        default: "unknown"
        }
    }

    static let optionNames: AudioCategoryOptionNames = .init(known: [
        (0x1, "mixWithOthers"),
        (0x2, "duckOthers"),
        (0x4, "allowBluetoothHFP"),
        (0x8, "defaultToSpeaker"),
        (0x11, "interruptSpokenAudioAndMixWithOthers"),
        (0x20, "allowBluetoothA2DP"),
        (0x40, "allowAirPlay"),
        (0x80, "overrideMutedMicrophoneInterruption"),
    ])
    #endif

    func observe(_ context: Context) {
        #if os(iOS)
        guard let sessionClass = objc_getClass("AVAudioSession") as? AnyClass,
              let session = Self.sharedInstance(sessionClass)
        else {
            return
        }

        report(session, reason: "initial", previousOutput: nil, into: context)

        // No queue: hopping to main would read the route after it had already changed again.
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("AVAudioSessionRouteChangeNotification"),
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let session = Self.sharedInstance(sessionClass) else {
                return
            }

            let info = notification.userInfo
            let raw = info?["AVAudioSessionRouteChangeReasonKey"] as? UInt
            let previousRoute = info?["AVAudioSessionRouteChangePreviousRouteKey"] as AnyObject?
            let previousOutput = (previousRoute?.value(forKey: "outputs") as? [AnyObject])?
                .first?
                .value(forKey: "portType") as? String

            self.report(
                session,
                reason: Self.named(raw),
                previousOutput: previousOutput,
                into: context
            )
        }
        #endif
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }
}
