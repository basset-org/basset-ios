@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

#if os(iOS)
import AVFoundation
#endif

/// Verdict logic tested against facts, not the framework — checkable without a phone.
struct AudioRoutingTests {
    /// play-and-record defaults to the earpiece; an app that asked for nothing sounds broken.
    @Test func theEarpieceWithNoSpeakerDefaultIsTheReportedFault() {
        #expect(
            AudioRouting.verdict(facts(.receiver)) == .earpieceAndSpeakerDefaultUnset
        )
    }

    /// Same route with the option set is a different finding — the option isn't deciding it.
    @Test func theEarpieceDespiteTheSpeakerDefaultIsItsOwnVerdict() {
        #expect(
            AudioRouting.verdict(facts(.receiver, defaultToSpeaker: true))
                == .earpieceDespiteSpeakerDefault
        )
    }

    /// Speaker without the default set is a temporary override, discarded by the next route change.
    @Test func theSpeakerWithoutTheDefaultIsHeldByAnOverride() {
        #expect(
            AudioRouting.verdict(facts(.speaker)) == .speakerHeldByTemporaryOverride
        )
    }

    @Test func theSpeakerWithTheDefaultSetIsWhereItBelongs() {
        #expect(
            AudioRouting.verdict(facts(.speaker, defaultToSpeaker: true)) == .speaker
        )
    }

    /// `categoryOptions` reads zero for a mode-implied speaker request, so the mode counts too.
    @Test func aModeThatImpliesTheSpeakerCountsAsHavingAskedForIt() {
        #expect(
            AudioRouting.verdict(facts(.receiver, modeImpliesSpeaker: true))
                == .earpieceDespiteSpeakerDefault
        )
    }

    /// Same fact, other branch — a mode implying speaker must not read as an override.
    @Test func aModeThatImpliesTheSpeakerIsNotAnOverride() {
        #expect(
            AudioRouting.verdict(facts(.speaker, modeImpliesSpeaker: true)) == .speaker
        )
    }

    /// Only play-and-record ever routes to the earpiece — speaker elsewhere is ordinary.
    @Test func theSpeakerUnderAPlaybackOnlyCategoryIsOrdinary() {
        #expect(
            AudioRouting.verdict(facts(.speaker, recordsAndPlays: false)) == .speaker
        )
    }

    @Test func aHandsFreeRouteIsCalledOutSeparatelyFromOtherAccessories() {
        #expect(AudioRouting.verdict(facts(.handsFree)) == .handsFreeProfile)
        #expect(AudioRouting.verdict(facts(.accessory)) == .accessory)
    }

    @Test func aRouteWithNoOutputIsReportedRatherThanSkipped() {
        #expect(AudioRouting.verdict(facts(.none)) == .noOutputRoute)
    }

    private func facts(
        _ output: AudioOutputKind,
        recordsAndPlays: Bool = true,
        modeImpliesSpeaker: Bool = false,
        defaultToSpeaker: Bool = false
    ) -> AudioRouteFacts {
        AudioRouteFacts(
            output: output,
            recordsAndPlays: recordsAndPlays,
            modeImpliesSpeaker: modeImpliesSpeaker,
            defaultToSpeaker: defaultToSpeaker
        )
    }
}

/// Input routing verdicts — category decides what's listening before hardware does.
struct AudioInputRoutingTests {
    /// A playback category with no mic route looks like a permission bug until named.
    @Test func aCategoryThatTakesNoInputOutranksWhateverIsAttached() {
        #expect(
            AudioRouting.inputVerdict(facts(.builtIn, categoryTakesInput: false))
                == .categoryTakesNoInput
        )
        #expect(
            AudioRouting.inputVerdict(facts(.wiredHeadset, categoryTakesInput: false))
                == .categoryTakesNoInput
        )
    }

    /// No input route under recording is distinct from a category that never asked for input.
    @Test func aRecordingCategoryWithNoInputIsItsOwnVerdict() {
        #expect(AudioRouting.inputVerdict(facts(.none)) == .noInputRoute)
    }

    @Test func eachInputPortReachesItsOwnVerdict() {
        #expect(AudioRouting.inputVerdict(facts(.builtIn)) == .builtInMicrophone)
        #expect(
            AudioRouting.inputVerdict(facts(.wiredHeadset)) == .wiredHeadsetMicrophone
        )
        #expect(AudioRouting.inputVerdict(facts(.handsFree)) == .handsFreeMicrophone)
        #expect(AudioRouting.inputVerdict(facts(.accessory)) == .accessoryMicrophone)
    }

    private func facts(
        _ input: AudioInputKind,
        categoryTakesInput: Bool = true
    ) -> AudioInputFacts {
        AudioInputFacts(input: input, categoryTakesInput: categoryTakesInput)
    }
}

/// The option bit field and the composite mask that breaks decoding it in declaration order.
struct AudioCategoryOptionNameTests {
    /// Mirrors the real table's shape — one option's mask contains another's only bit.
    private let table: AudioCategoryOptionNames = .init(known: [
        (0x1, "mixWithOthers"),
        (0x2, "duckOthers"),
        (0x8, "defaultToSpeaker"),
        (0x11, "interruptSpokenAudioAndMixWithOthers"),
    ])

    @Test func singleBitsDecodeToTheirOwnNames() {
        #expect(table.names(0xa) == ["defaultToSpeaker", "duckOthers"])
    }

    /// Declaration order would report mixing on a session that only asked to interrupt speech.
    @Test func aCompositeMaskConsumesTheBitsItContains() {
        #expect(table.names(0x11) == ["interruptSpokenAudioAndMixWithOthers"])
    }

    @Test func aCompositeMaskLeavesUnrelatedBitsAlone() {
        #expect(
            table.names(0x13) == ["duckOthers", "interruptSpokenAudioAndMixWithOthers"]
        )
    }

    /// An option a newer OS adds is reported as unaccounted for rather than dropped.
    @Test func bitsTheTableDoesNotKnowAreReportedAsThemselves() {
        #expect(table.names(0x1002) == ["duckOthers", "unknown(0x1000)"])
    }

    @Test func noOptionsIsAnEmptyList() {
        #expect(table.names(0).isEmpty)
    }

    /// An empty string is indistinguishable from an unwritten field — render "none" instead.
    @Test func noOptionsRendersAsAWordRatherThanAnEmptyString() {
        #expect(table.rendered(0) == "none")
        #expect(table.rendered(0x2) == "duckOthers")
    }
}

#if os(iOS)
/// No real earpiece or speaker in a simulator — proves the mechanism safe, not real routing.
@Suite(.serialized)
struct AudioRouteWiringTests {
    @Test func activatingReportsTheRouteBeforeAnythingChanges() {
        let harness = InstrumentHarness<AudioRoute>()
        harness.start()
        defer { harness.stop() }

        let reading = harness.waitForReading()
        #expect(harness.value(.changeReason, in: reading) == "initial")
        // Verdict and category on every reading, or "why is it in the earpiece" goes unanswered.
        #expect(harness.value(.audioRouteVerdict, in: reading) != nil)
        #expect(harness.value(.audioCategory, in: reading) != nil)
        #expect(harness.value(.audioOutputPort, in: reading) != nil)
        #expect(harness.value(.outputVolume, in: reading) != nil)
        #expect(harness.value(.audioInputVerdict, in: reading) != nil)
        #expect(harness.value(.audioInputAvailable, in: reading) != nil)
        #expect(harness.value(.audioOutputCount, in: reading) != nil)
    }

    /// `multiRoute` admits input despite reading like a playback category from its name.
    @Test func everyCategoryIsSortedByWhetherItAdmitsInput() {
        #expect(AudioRoute.admitsInput(AVAudioSession.Category.record.rawValue))
        #expect(AudioRoute.admitsInput(AVAudioSession.Category.playAndRecord.rawValue))
        #expect(AudioRoute.admitsInput(AVAudioSession.Category.multiRoute.rawValue))
        #expect(!AudioRoute.admitsInput(AVAudioSession.Category.playback.rawValue))
        #expect(!AudioRoute.admitsInput(AVAudioSession.Category.ambient.rawValue))
        #expect(!AudioRoute.admitsInput(AVAudioSession.Category.soloAmbient.rawValue))
    }

    /// `playback` admits no input regardless of hardware — provable without a real device.
    @Test func aPlaybackCategoryReportsThatNothingIsListening() throws {
        let session = AVAudioSession.sharedInstance()
        let category = session.category
        let mode = session.mode
        let options = session.categoryOptions
        defer {
            try? session.setCategory(category, mode: mode, options: options)
        }

        try session.setCategory(.playback)

        let harness = InstrumentHarness<AudioRoute>()
        harness.start()
        defer { harness.stop() }

        #expect(
            harness.value(.audioInputVerdict, in: harness.waitForReading())
                == "categoryTakesNoInput"
        )
    }

    @Test func aRouteChangeIsReportedWithTheReasonTheSystemGave() {
        let harness = InstrumentHarness<AudioRoute>()
        harness.start()
        defer { harness.stop() }

        harness.waitForReading()
        harness.forget()

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.categoryChange.rawValue,
            ]
        )

        let reading = harness.waitForReading()
        #expect(harness.value(.changeReason, in: reading) == "categoryChange")
    }

    /// Without detaching, an instrument started and stopped twice reports every route change twice.
    @Test func stoppingDetachesTheObserver() {
        let harness = InstrumentHarness<AudioRoute>()
        harness.start()
        harness.waitForReading()
        harness.stop()
        harness.forget()

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.override.rawValue,
            ]
        )

        #expect(harness.waitForReading(timeout: 0.5) == nil)
    }

    /// `categoryOptions` misses a mode's side effects — video chat sets speaker silently.
    @Test func aModesSideEffectsDoNotAppearInTheOptionField() throws {
        let session = AVAudioSession.sharedInstance()
        let category = session.category
        let mode = session.mode
        let options = session.categoryOptions
        defer {
            try? session.setCategory(category, mode: mode, options: options)
        }

        try session.setCategory(.playAndRecord, mode: .videoChat, options: [])

        #expect(session.mode == .videoChat)
        #expect(session.categoryOptions.contains(.defaultToSpeaker) == false)
    }

    /// A paired accessory's name comes from whoever owns it — only ports iOS names are reported.
    @Test func onlyPortsTheSystemNamesCarryANameIntoAReading() {
        let harness = InstrumentHarness<AudioRoute>()
        harness.start()
        defer { harness.stop() }

        let reading = harness.waitForReading()
        let port = harness.value(.audioOutputPort, in: reading)
        let named = harness.value(.audioOutputName, in: reading) != nil
        let systemNamed = [
            AVAudioSession.Port.builtInReceiver, .builtInSpeaker, .builtInMic,
            .headphones, .headsetMic, .lineIn, .lineOut,
        ].map(\.rawValue)

        #expect(named == systemNamed.contains(port ?? ""))
    }
}
#endif
