import BassetECS
import Foundation

#if os(iOS)
import AVFoundation
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

final class AudioRoute: StreamingInstrument {
    static let id: InstrumentID = .audioRoute
    static let entity = Entity.ID.audioRoute

    private var observer: NSObjectProtocol?

    init() {}

    func observe(_ context: Context) {
        #if os(iOS)
        report(reason: "initial", previousOutput: nil, into: context)

        // No queue: hopping to main would read the route after it had already changed again.
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let info = notification.userInfo
            let raw = info?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let previous = info?[AVAudioSessionRouteChangePreviousRouteKey]
                as? AVAudioSessionRouteDescription
            self?.report(
                reason: Self.named(raw.flatMap(AVAudioSession.RouteChangeReason.init)),
                previousOutput: previous?.outputs.first?.portType.rawValue,
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

    #if os(iOS)
    /// Never sets category, mode, override or active state — it cannot be the reason audio moved.
    private func report(
        reason: String,
        previousOutput: String?,
        into context: Context
    ) {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let output = route.outputs.first
        let input = route.inputs.first
        let options = session.categoryOptions
        let category = session.category

        let inputFacts = AudioInputFacts(
            input: Self.inputKind(of: input?.portType),
            categoryTakesInput: Self.admitsInput(category)
        )
        let facts = AudioRouteFacts(
            output: Self.kind(of: output?.portType),
            recordsAndPlays: session.category == .playAndRecord,
            modeImpliesSpeaker: session.mode == .videoChat,
            defaultToSpeaker: options.contains(.defaultToSpeaker)
        )

        context.emit { out in
            out.put(.changeReason(reason))
            out.put(.audioRouteVerdict(AudioRouting.verdict(facts).rawValue))
            out.put(.audioInputVerdict(AudioRouting.inputVerdict(inputFacts).rawValue))
            out.put(.audioCategory(category.rawValue))
            out.put(.audioMode(session.mode.rawValue))
            out.put(.audioCategoryOptions(Self.optionNames.rendered(options.rawValue)))
            out.put(.outputVolume(session.outputVolume))
            out.put(.otherAudioPlaying(session.isOtherAudioPlaying))
            out.put(.secondaryAudioSilenced(session.secondaryAudioShouldBeSilencedHint))

            if let output {
                out.put(.audioOutputPort(output.portType.rawValue))
                if let name = Self.reportableName(of: output) {
                    out.put(.audioOutputName(name))
                }
            }
            out.put(.audioOutputCount(UInt32(route.outputs.count)))
            out.put(.audioInputAvailable(session.isInputAvailable))

            if let available = session.availableInputs {
                out.put(.availableInputCount(UInt32(available.count)))
            }
            if let preferred = session.preferredInput {
                out.put(.audioPreferredInputHonored(preferred.uid == input?.uid))
            }
            if let input {
                out.put(.audioInputPort(input.portType.rawValue))
                if Self.namesAreTheSystemsOwn(input) {
                    out.put(.audioInputName(input.portName))
                    if let source = input.selectedDataSource {
                        out.put(.audioInputDataSource(source.dataSourceName))
                        if let pattern = source.selectedPolarPattern {
                            out.put(.audioInputPolarPattern(pattern.rawValue))
                        }
                        if let orientation = source.orientation {
                            out.put(.audioInputOrientation(orientation.rawValue))
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
    private static func reportableName(of port: AVAudioSessionPortDescription)
        -> String?
    {
        namesAreTheSystemsOwn(port) ? port.portName : nil
    }

    private static func namesAreTheSystemsOwn(_ port: AVAudioSessionPortDescription) -> Bool {
        switch port.portType {
        case .builtInMic,
             .builtInReceiver,
             .builtInSpeaker,
             .headphones,
             .headsetMic,
             .lineIn,
             .lineOut:
            true
        default:
            false
        }
    }

    private static func kind(of port: AVAudioSession.Port?) -> AudioOutputKind {
        guard let port else {
            return .none
        }

        switch port {
        case .builtInReceiver: return .receiver
        case .builtInSpeaker: return .speaker
        case .bluetoothHFP: return .handsFree
        default: return .accessory
        }
    }

    /// The three categories that admit input; every other leaves the route without a microphone.
    static func admitsInput(_ category: AVAudioSession.Category) -> Bool {
        category == .record || category == .playAndRecord || category == .multiRoute
    }

    private static func inputKind(of port: AVAudioSession.Port?) -> AudioInputKind {
        guard let port else {
            return .none
        }

        switch port {
        case .builtInMic: return .builtIn
        case .headsetMic: return .wiredHeadset
        case .bluetoothHFP: return .handsFree
        default: return .accessory
        }
    }

    private static func named(_ reason: AVAudioSession.RouteChangeReason?) -> String {
        switch reason {
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        case .none,
             .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    static let optionNames: AudioCategoryOptionNames = .init(known: [
        (AVAudioSession.CategoryOptions.mixWithOthers.rawValue, "mixWithOthers"),
        (AVAudioSession.CategoryOptions.duckOthers.rawValue, "duckOthers"),
        (handsFreeOption().rawValue, "allowBluetoothHFP"),
        (AVAudioSession.CategoryOptions.defaultToSpeaker.rawValue, "defaultToSpeaker"),
        (
            AVAudioSession.CategoryOptions.interruptSpokenAudioAndMixWithOthers
                .rawValue,
            "interruptSpokenAudioAndMixWithOthers"
        ),
        (
            AVAudioSession.CategoryOptions.allowBluetoothA2DP.rawValue,
            "allowBluetoothA2DP"
        ),
        (AVAudioSession.CategoryOptions.allowAirPlay.rawValue, "allowAirPlay"),
        (
            AVAudioSession.CategoryOptions.overrideMutedMicrophoneInterruption.rawValue,
            "overrideMutedMicrophoneInterruption"
        ),
    ])

    /// Old spelling `allowBluetooth` compiles pre-rename too; reported under the current name.
    @available(iOS, deprecated: 8.0)
    private static func handsFreeOption() -> AVAudioSession.CategoryOptions {
        .allowBluetooth
    }
    #endif
}
