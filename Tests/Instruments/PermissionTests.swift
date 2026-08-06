@testable import Basset
import BassetECS
import Foundation
import Testing

struct PermissionVocabularyTests {
    /// The trap this whole type exists for. Speech and MediaPlayer number denied
    /// before restricted where every other framework does the reverse, so a
    /// single shared mapping would report a user who tapped Don't Allow as
    /// restricted by their device — a confident wrong answer about who refused.
    @Test func deniedAndRestrictedAreNotInTheSameOrderEverywhere() {
        #expect(PermissionProbe.Vocabulary.standard.name(of: 1) == "restricted")
        #expect(PermissionProbe.Vocabulary.standard.name(of: 2) == "denied")
        #expect(PermissionProbe.Vocabulary.deniedBeforeRestricted.name(of: 1) == "denied")
        #expect(PermissionProbe.Vocabulary.deniedBeforeRestricted
            .name(of: 2) == "restricted")
    }

    @Test func everyVocabularyAgreesOnTheTwoEndsOfTheScale() {
        let vocabularies: [PermissionProbe.Vocabulary] = [
            .standard, .withLimited, .deniedBeforeRestricted,
        ]

        #expect(vocabularies.allSatisfy { $0.name(of: 0) == "notDetermined" })
        #expect(vocabularies.allSatisfy { $0.name(of: 3) == "authorized" })
    }

    /// EventKit split authorized into full and write-only in iOS 17, so its 3 is
    /// not the other frameworks' 3 and cannot be spelled the same.
    @Test func eventKitNamesItsOwnSplitOfAuthorized() {
        #expect(PermissionProbe.Vocabulary.eventKit.name(of: 3) == "fullAccess")
        #expect(PermissionProbe.Vocabulary.eventKit.name(of: 4) == "writeOnly")
    }

    @Test func onlyTheVocabulariesThatHaveALimitedCaseReportOne() {
        #expect(PermissionProbe.Vocabulary.withLimited.name(of: 4) == "limited")
        #expect(PermissionProbe.Vocabulary.standard.name(of: 4) == "unrecognised(4)")
    }

    /// A capture may come from an OS newer than this SDK. Naming an unknown
    /// value after the nearest case we do know would assert something about a
    /// user's choice that was never read.
    @Test func aStatusThisSdkPredatesIsReportedAsItsNumber() {
        #expect(PermissionProbe.Vocabulary.standard.name(of: 9) == "unrecognised(9)")
        #expect(PermissionProbe.Vocabulary.standard.name(of: -1) == "unrecognised(-1)")
    }
}

struct PermissionProbeTests {
    /// Every probe must name a real class and a real selector on this SDK, and
    /// the check that it does is the probe running: a typo produces no finding
    /// rather than an error, which is the failure mode the whole domain exists
    /// to avoid reporting as "nothing happened".
    @Test func everyProbeNamesADistinctSubject() {
        let subjects = PermissionProbe.all.map(\.subject)

        #expect(Set(subjects).count == subjects.count)
    }

    @Test func everyProbeDeclaresAUsageDescriptionKeyToLookFor() {
        #expect(PermissionProbe.all.allSatisfy { !$0.usageDescriptionKeys.isEmpty })
        #expect(
            PermissionProbe.all.allSatisfy {
                $0.usageDescriptionKeys.allSatisfy { $0.hasPrefix("NS") }
            }
        )
    }

    /// Siri is absent by decision, not oversight.
    /// `INPreferences.siriAuthorizationStatus` is a status read that prompts
    /// nothing and needs no usage description, and it raises
    /// `NSInternalInconsistencyException` without the `com.apple.developer.siri`
    /// entitlement — an ObjC exception Swift cannot catch, which terminates any
    /// app that loads Intents without it. The simulator suite found this by
    /// crashing; this pins it so nothing adds the probe back.
    @Test func siriIsNotProbedBecauseAskingItRequiresAnEntitlement() {
        #expect(PermissionProbe.all.contains { $0.className == "INPreferences" } == false)
    }

    /// basset never asks for a permission, so no probe may name a selector that
    /// would. Reading a status prompts nothing; requesting one prompts, and
    /// requesting one the Info.plist does not cover terminates the process.
    @Test func noProbeCallsARequestMethod() {
        for probe in PermissionProbe.all {
            guard case .classMethod(let selector, _, _) = probe.answer else {
                continue
            }

            #expect(
                selector.description.lowercased().contains("request") == false,
                "\(probe.subject) would prompt"
            )
        }
    }

    /// A framework the app does not link answers nothing, and that absence is
    /// the finding — this test build links none of them, so the probe table
    /// yielding an empty set is the mechanism working.
    @Test func aFrameworkThatIsNotLinkedProducesNoFinding() {
        let probe = PermissionProbe(
            subject: "nothing",
            className: "BassetClassThatDoesNotExist",
            answer: .classMethod(Selector(("authorizationStatus")), .none, .standard),
            usageDescriptionKeys: ["NSNothingUsageDescription"]
        )

        #expect(probe.finding(in: .main) == nil)
    }

    @Test func aClassPresentWithoutTheSelectorProducesNoFindingEither() {
        let probe = PermissionProbe(
            subject: "nothing",
            className: "NSObject",
            answer: .classMethod(
                Selector(("bassetSelectorThatDoesNotExist")),
                .none,
                .standard
            ),
            usageDescriptionKeys: ["NSNothingUsageDescription"]
        )

        #expect(probe.finding(in: .main) == nil)
    }

    /// The call path itself, against a framework this test process really does
    /// load. A wrong `@convention(c)` signature or a mistyped selector shows up
    /// here as a status outside every vocabulary rather than as a crash, which
    /// is the only cheap way to check an `unsafeBitCast` is reading the right
    /// bytes.
    @Test func aProbeAgainstALoadedFrameworkAnswersAStatusItCanName() throws {
        let findings = PermissionProbe.findings()
        try #require(
            !findings.isEmpty,
            "no permission-gated framework is loaded in this test process"
        )

        for finding in findings {
            guard let status = finding.status else {
                continue
            }

            #expect(
                status.hasPrefix("unrecognised") == false,
                "\(finding.subject) answered \(status)"
            )
        }
    }

    @Test func anUnknowableSubjectIsStillReportedWhenItsFrameworkIsThere() {
        let probe = PermissionProbe(
            subject: "health",
            className: "NSObject",
            answer: .unknowable(
                "read authorization is indistinguishable from absent data"
            ),
            usageDescriptionKeys: ["NSHealthShareUsageDescription"]
        )

        let finding = probe.finding(in: .main)

        #expect(finding?.status == nil)
        #expect(finding?.unknowableBecause != nil)
    }
}

struct PermissionStatusTests {
    @Test func noLinkedFrameworkIsReportedRatherThanLeftSilent() {
        var out = readings()
        PermissionStatus.write([], into: &out)

        #expect(out.componentsWritten == [.mechanismStatus])
    }

    @Test func eachFindingBecomesItsOwnReading() {
        var out = readings()
        PermissionStatus.write(
            [
                PermissionFinding(
                    subject: "camera",
                    status: "denied",
                    unknowableBecause: nil,
                    usageDescriptionDeclared: true
                ),
                PermissionFinding(
                    subject: "contacts",
                    status: "notDetermined",
                    unknowableBecause: nil,
                    usageDescriptionDeclared: false
                ),
            ],
            into: &out
        )

        #expect(out.sealedSiblings().count == 1)
        #expect(rendered(out.sealed(), .permissionSubject) == "camera")
        #expect(rendered(out.sealed(), .authorizationStatus) == "denied")
        #expect(rendered(out.sealedSiblings()[0], .usageDescriptionDeclared) == "false")
    }

    /// The pairing that is the whole point: a subject nobody has answered yet,
    /// in a build carrying no usage description, is an app that terminates the
    /// moment it asks. Both halves have to be in the same row for a reader to
    /// see it without a join.
    @Test func aStatusAndItsUsageDescriptionArriveTogether() {
        var out = readings()
        PermissionStatus.write(
            [
                PermissionFinding(
                    subject: "microphone",
                    status: "notDetermined",
                    unknowableBecause: nil,
                    usageDescriptionDeclared: false
                ),
            ],
            into: &out
        )

        #expect(rendered(out.sealed(), .authorizationStatus) == "notDetermined")
        #expect(rendered(out.sealed(), .usageDescriptionDeclared) == "false")
    }

    private func readings() -> Readings {
        Readings(
            entity: .permission,
            instrumentName: "permissions.status"
        )
    }

    private func rendered(_ entity: Entity, _ id: Component.WireID) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}
