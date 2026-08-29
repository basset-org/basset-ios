@testable import Basset
import BassetEntityComponent
import Foundation
import Testing

struct PermissionVocabularyTests {
    /// Speech and MediaPlayer number denied before restricted; a shared mapping would swap them.
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

    /// EventKit split authorized into full and write-only in iOS 17, so its 3 differs.
    @Test func eventKitNamesItsOwnSplitOfAuthorized() {
        #expect(PermissionProbe.Vocabulary.eventKit.name(of: 3) == "fullAccess")
        #expect(PermissionProbe.Vocabulary.eventKit.name(of: 4) == "writeOnly")
    }

    @Test func onlyTheVocabulariesThatHaveALimitedCaseReportOne() {
        #expect(PermissionProbe.Vocabulary.withLimited.name(of: 4) == "limited")
        #expect(PermissionProbe.Vocabulary.standard.name(of: 4) == "unrecognised(4)")
    }

    /// An OS newer than this SDK may return an unknown value; reported as its number, not guessed.
    @Test func aStatusThisSdkPredatesIsReportedAsItsNumber() {
        #expect(PermissionProbe.Vocabulary.standard.name(of: 9) == "unrecognised(9)")
        #expect(PermissionProbe.Vocabulary.standard.name(of: -1) == "unrecognised(-1)")
    }
}

struct PermissionProbeTests {
    /// A typo in a probe's class or selector produces no finding rather than an error.
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

    /// `INPreferences.siriAuthorizationStatus` raises without the Siri entitlement.
    @Test func siriIsNotProbedBecauseAskingItRequiresAnEntitlement() {
        #expect(PermissionProbe.all.contains { $0.className == "INPreferences" } == false)
    }

    /// Requesting a permission uncovered by Info.plist terminates the process.
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

    /// This test build links none of these frameworks, so an empty result is the mechanism working.
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

    /// A wrong `@convention(c)` signature shows as a status outside every vocabulary, not a crash.
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

        #expect(out.build().componentIDs == [.mechanismStatus])
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

        #expect(out.additionalEntities().count == 1)
        #expect(rendered(out.build(), .permissionSubject) == "camera")
        #expect(rendered(out.build(), .authorizationStatus) == "denied")
        #expect(rendered(out.additionalEntities()[0], .usageDescriptionDeclared) == "false")
    }

    /// Status and usage-description share a row so a reader sees the pairing without a join.
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

        #expect(rendered(out.build(), .authorizationStatus) == "notDetermined")
        #expect(rendered(out.build(), .usageDescriptionDeclared) == "false")
    }

    private func readings() -> Readings {
        Readings(.permission)
    }

    private func rendered(_ entity: Entity, _ id: Component.ID) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}
