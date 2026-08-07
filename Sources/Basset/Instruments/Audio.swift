import BassetECS
import Foundation

#if os(iOS)
import AVFoundation
#endif

/// Which physical output is carrying the app's audio, reduced to the cases the
/// routing rules treat differently. The port type itself is emitted beside this;
/// what the verdict needs is only whether the earpiece, the speaker, a
/// hands-free profile or something else is on the end.
enum AudioOutputKind: String, Sendable {
    case receiver
    case speaker
    case handsFree
    case accessory
    case none
}

/// The state of the session that decides where output lands, in terms that hold
/// no framework constant. Reading them off `AVAudioSession` is one switch; the
/// rules below are the part worth testing.
struct AudioRouteFacts: Sendable {
    let output: AudioOutputKind
    /// The category is play-and-record, the only one that routes to the earpiece.
    let recordsAndPlays: Bool
    /// The mode sets the speaker default as a side effect of being set at all.
    ///
    /// Kept separate from `defaultToSpeaker` because **`categoryOptions` does
    /// not report what a mode implied** — a session set to video chat reads back
    /// an option field of zero while the mode reads back as video chat, which
    /// `aModesSideEffectsDoNotAppearInTheOptionField` runs against the framework
    /// to establish. Deriving the request from the option field alone therefore
    /// reports that nothing asked for the speaker on a session that did.
    let modeImpliesSpeaker: Bool
    /// The option, which is what the caller passed, and nothing more.
    let defaultToSpeaker: Bool

    /// The speaker was asked for, by either route.
    var speakerRequested: Bool {
        defaultToSpeaker || modeImpliesSpeaker
    }
}

/// What a caller is told about the route. Every case is a state a user can hear.
enum AudioRouteVerdict: String, Sendable {
    /// Output is the earpiece, and nothing asked for the speaker. The app is
    /// audible only when the phone is held to the ear.
    case earpieceAndSpeakerDefaultUnset
    /// Output is the earpiece although the speaker default is set, so the option
    /// is not deciding the route and something else is.
    case earpieceDespiteSpeakerDefault
    /// Output is the speaker under a category that defaults to the earpiece,
    /// with no speaker default set — the only thing that puts it there is
    /// `overrideOutputAudioPort`, which lasts until the route next changes.
    /// Plugging in and unplugging a headset drops this app back to the earpiece.
    case speakerHeldByTemporaryOverride
    case speaker
    /// A Bluetooth hands-free route. It carries a call-grade channel in both
    /// directions, so music and media sound narrowband on it.
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

/// Turns a category-option bit field into the names of the options set in it.
///
/// A table rather than a chain of tests, because one option is a composite:
/// interrupt-spoken-audio carries the mix-with-others bit inside its own mask,
/// so testing single bits in declaration order reports mixing on a session that
/// only asked to interrupt. Wider masks are consumed first and their bits
/// removed, which also means the two are indistinguishable when both are set —
/// the bit field cannot tell them apart either.
///
/// Bits left over after the table has been applied are reported as their own
/// hexadecimal value rather than dropped. An option added to a later OS is then
/// visible as something unaccounted for instead of as an option nobody set.
struct AudioCategoryOptionNames {
    let known: [(mask: UInt, name: String)]

    /// What a reading carries: the names joined, or a word rather than an empty
    /// string, so "no options are set" and "the options were not read" are not
    /// the same reading.
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
            found.append("unknown(0x\(String(remaining, radix: 16)))")
        }
        return found
    }
}

final class AudioRoute: StreamingInstrument {
    static let id: InstrumentWireID = .audioRoute
    static let entity = Entity.WireID.audioRoute

    private var observer: NSObjectProtocol?

    init() {}

    func observe(_ context: Context) {
        #if os(iOS)
        report(reason: "initial", previousOutput: nil, into: context)

        // No queue, so this runs on the thread the system posts on rather than
        // hopping to the main one. The route is read inside the handler, and a
        // hop would read whatever it had become by the time the main queue got
        // round to it — which on a device is routinely a different route.
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
    /// Nothing here sets a category, a mode, an override or an active state. A
    /// session is process-wide and last-writer-wins, so a tool that configured
    /// one to look at it would be the reason the app's audio moved.
    private func report(
        reason: String,
        previousOutput: String?,
        into context: Context
    ) {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let output = route.outputs.first
        let options = session.categoryOptions

        let facts = AudioRouteFacts(
            output: Self.kind(of: output?.portType),
            recordsAndPlays: session.category == .playAndRecord,
            modeImpliesSpeaker: session.mode == .videoChat,
            defaultToSpeaker: options.contains(.defaultToSpeaker)
        )

        context.emit { out in
            out.put(.changeReason(reason))
            out.put(.audioRouteVerdict(AudioRouting.verdict(facts).rawValue))
            out.put(.audioCategory(session.category.rawValue))
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
            if let input = route.inputs.first {
                out.put(.audioInputPort(input.portType.rawValue))
            }
            if let previousOutput {
                out.put(.audioPreviousOutputPort(previousOutput))
            }
        }
    }

    /// A port's name is the accessory's own, and an accessory is named by
    /// whoever owns it — a paired headset carries a person's name far more often
    /// than not. Built-in and wired ports have fixed names iOS chose, so those
    /// are the ones that can be reported; everything else is described by its
    /// type alone.
    private static func reportableName(of port: AVAudioSessionPortDescription)
        -> String?
    {
        switch port.portType {
        case .builtInMic,
             .builtInReceiver,
             .builtInSpeaker,
             .headphones,
             .headsetMic,
             .lineIn,
             .lineOut:
            port.portName
        default:
            nil
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

    /// The hands-free option is spelled `allowBluetooth` in SDKs before the one
    /// that renamed it `allowBluetoothHFP`, and only the old spelling compiles
    /// against both. Same bit either way, so the reported name is the current
    /// one. Declared deprecated here so the rename does not warn on the SDKs
    /// that carry it.
    @available(iOS, deprecated: 8.0)
    private static func handsFreeOption() -> AVAudioSession.CategoryOptions {
        .allowBluetooth
    }
    #endif
}
