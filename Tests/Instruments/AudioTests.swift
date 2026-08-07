@testable import Basset
import BassetECS
import Foundation
import Testing

#if os(iOS)
import AVFoundation
#endif

/// The routing rules, over the facts rather than over the framework. Reading
/// those facts off a session is one switch each; deciding what they mean is the
/// part a phone would otherwise be needed to check.
struct AudioRoutingTests {
    /// The bug the domain exists for: play-and-record routes to the earpiece
    /// unless something asks otherwise, and an app that asked for nothing sounds
    /// broken to everyone holding the phone away from their face.
    @Test func theEarpieceWithNoSpeakerDefaultIsTheReportedFault() {
        #expect(
            AudioRouting.verdict(facts(.receiver)) == .earpieceAndSpeakerDefaultUnset
        )
    }

    /// The same route with the option set is a different finding: the option is
    /// there and is not deciding the route, so the answer is not "set it".
    @Test func theEarpieceDespiteTheSpeakerDefaultIsItsOwnVerdict() {
        #expect(
            AudioRouting.verdict(facts(.receiver, defaultToSpeaker: true))
                == .earpieceDespiteSpeakerDefault
        )
    }

    /// Speaker under a category that defaults to the earpiece, with nothing
    /// standing in the state to keep it there, means a temporary override is —
    /// and that override is discarded by the next route change.
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

    /// The mode asks for the speaker as much as the option does, and
    /// `categoryOptions` does not report what a mode implied — a session set to
    /// video chat reads back an option field of zero. Reading the option alone
    /// therefore tells a video-chat app on the earpiece that nothing asked for
    /// the speaker, which is the one thing it did do.
    @Test func aModeThatImpliesTheSpeakerCountsAsHavingAskedForIt() {
        #expect(
            AudioRouting.verdict(facts(.receiver, modeImpliesSpeaker: true))
                == .earpieceDespiteSpeakerDefault
        )
    }

    /// The same fact on the other branch: a mode that implies the speaker must
    /// not be read as an override, or every video-chat app reports a route about
    /// to be lost.
    @Test func aModeThatImpliesTheSpeakerIsNotAnOverride() {
        #expect(
            AudioRouting.verdict(facts(.speaker, modeImpliesSpeaker: true)) == .speaker
        )
    }

    /// Only play-and-record ever routes to the earpiece, so the speaker under
    /// any other category is the ordinary outcome.
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

/// The option bit field, and the composite mask that makes decoding it in
/// declaration order wrong.
struct AudioCategoryOptionNameTests {
    /// The shape the real table has: one option whose mask contains another
    /// option's only bit. Written out here rather than taken from the framework
    /// so the rule is checkable on a machine that has no audio session.
    private let table: AudioCategoryOptionNames = .init(known: [
        (0x1, "mixWithOthers"),
        (0x2, "duckOthers"),
        (0x8, "defaultToSpeaker"),
        (0x11, "interruptSpokenAudioAndMixWithOthers"),
    ])

    @Test func singleBitsDecodeToTheirOwnNames() {
        #expect(table.names(0xa) == ["defaultToSpeaker", "duckOthers"])
    }

    /// The trap. Testing bits in declaration order reports mixing on a session
    /// that asked only to interrupt spoken audio, because that option's mask
    /// carries the mixing bit inside it.
    @Test func aCompositeMaskConsumesTheBitsItContains() {
        #expect(table.names(0x11) == ["interruptSpokenAudioAndMixWithOthers"])
    }

    @Test func aCompositeMaskLeavesUnrelatedBitsAlone() {
        #expect(
            table.names(0x13) == ["duckOthers", "interruptSpokenAudioAndMixWithOthers"]
        )
    }

    /// An option a later OS adds is reported as unaccounted for rather than
    /// dropped, so a reading never claims a set of options it could not name.
    @Test func bitsTheTableDoesNotKnowAreReportedAsThemselves() {
        #expect(table.names(0x1002) == ["duckOthers", "unknown(0x1000)"])
    }

    @Test func noOptionsIsAnEmptyList() {
        #expect(table.names(0).isEmpty)
    }

    /// An empty string in a reading is indistinguishable from an option list
    /// nothing wrote, so the rendered form says so in a word.
    @Test func noOptionsRendersAsAWordRatherThanAnEmptyString() {
        #expect(table.rendered(0) == "none")
        #expect(table.rendered(0x2) == "duckOthers")
    }
}

#if os(iOS)
/// The mechanism against the real framework: a session that answers, a
/// notification the instrument is actually subscribed to, and a reading out the
/// other end.
///
/// **What a simulator cannot prove.** It has no earpiece and no speaker — the
/// route it reports is the host machine's output device — so no verdict reached
/// here describes hardware an app will run on, and the route change is posted by
/// the test rather than by the system moving audio between two real ports. What
/// this does establish is that reading the session's state is safe in a live
/// process, that the instrument registers and tears down, and that a reason
/// arrives decoded rather than as a number.
@Suite(.serialized)
struct AudioRouteWiringTests {
    @Test func activatingReportsTheRouteBeforeAnythingChanges() {
        let harness = InstrumentHarness<AudioRoute>()
        harness.start()
        defer { harness.stop() }

        let reading = harness.waitForReading()
        #expect(harness.value(.changeReason, in: reading) == "initial")
        // A verdict and a category on every reading, or a caller asking why the
        // audio is in the earpiece gets a reading that does not answer.
        #expect(harness.value(.audioRouteVerdict, in: reading) != nil)
        #expect(harness.value(.audioCategory, in: reading) != nil)
        #expect(harness.value(.audioOutputPort, in: reading) != nil)
        #expect(harness.value(.outputVolume, in: reading) != nil)
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

    /// Stopping has to detach the observer. Without it an instrument started and
    /// stopped twice reports every route change twice.
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

    /// A paired accessory is named by whoever owns it, so the reported name is
    /// limited to ports iOS names itself.
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
