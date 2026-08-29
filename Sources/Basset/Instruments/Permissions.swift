import BassetEntityComponent
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Polls on foreground; no framework posts a change — Settings changes usually relaunch the app.
final class PermissionChanges: Streamable, PlainInstrument {
    static let id: InstrumentID = .permissionChanges

    private let lastSeen: Mutex<[String: String]> = .init([:])
    private var observer: NSObjectProtocol?

    init() {}

    func observe(_ context: Context) {
        // Baseline first, so a later row saying a status changed also says what it changed from.
        emit(PermissionProbe.findings(), into: context)

        #if canImport(UIKit)
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else {
                return
            }

            self.emit(self.moved(in: PermissionProbe.findings()), into: context)
        }
        #endif
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        lastSeen.withLock { $0.removeAll() }
    }

    /// A subject with no status (HealthKit) never counts as moved — that's the mechanism talking.
    private func moved(in findings: [PermissionFinding]) -> [PermissionFinding] {
        lastSeen.withLock { seen in
            findings.filter { finding in
                guard let status = finding.status else {
                    return false
                }

                return seen[finding.subject] != status
            }
        }
    }

    private func emit(_ findings: [PermissionFinding], into context: Context) {
        guard !findings.isEmpty else {
            return
        }

        lastSeen.withLock { seen in
            for finding in findings {
                guard let status = finding.status else {
                    continue
                }

                seen[finding.subject] = status
            }
        }
        context.emit { out in
            PermissionStatus.write(findings, into: &out)
        }
    }
}

/// Reads via the ObjC runtime, never calls `request*` — camera/mic's class is always linked.
struct PermissionProbe {
    /// Status enums aren't one ordering — Speech/MediaPlayer swap denied and restricted.
    enum Vocabulary {
        case standard
        case withLimited
        case deniedBeforeRestricted
        case eventKit

        /// A value past the end predates this SDK — reported as its number, not a guessed case.
        private static func name(_ raw: Int, in names: [String]) -> String {
            guard raw >= 0, raw < names.count else {
                return "unrecognised(\(raw))"
            }

            return names[raw]
        }

        func name(of raw: Int) -> String {
            switch self {
            case .standard:
                Self.name(
                    raw,
                    in: ["notDetermined", "restricted", "denied", "authorized"]
                )
            case .withLimited:
                Self.name(
                    raw,
                    in: ["notDetermined", "restricted", "denied", "authorized", "limited"]
                )
            case .deniedBeforeRestricted:
                Self.name(
                    raw,
                    in: ["notDetermined", "denied", "restricted", "authorized"]
                )
            case .eventKit:
                Self.name(
                    raw,
                    in: [
                        "notDetermined",
                        "restricted",
                        "denied",
                        "fullAccess",
                        "writeOnly",
                    ]
                )
            }
        }
    }

    enum Argument {
        case none
        case integer(Int)
        case mediaType(String)
    }

    enum Answer {
        case classMethod(Selector, Argument, Vocabulary)
        /// HealthKit-style: denied is indistinguishable from absent, so reported, not omitted.
        case unknowable(String)
    }

    static let all: [PermissionProbe] = [
        PermissionProbe(
            subject: "camera",
            className: "AVCaptureDevice",
            answer: .classMethod(
                Selector(("authorizationStatusForMediaType:")),
                .mediaType("vide"),
                .standard
            ),
            usageDescriptionKeys: ["NSCameraUsageDescription"]
        ),
        PermissionProbe(
            subject: "microphone",
            className: "AVCaptureDevice",
            answer: .classMethod(
                Selector(("authorizationStatusForMediaType:")),
                .mediaType("soun"),
                .standard
            ),
            usageDescriptionKeys: ["NSMicrophoneUsageDescription"]
        ),
        PermissionProbe(
            subject: "photoLibrary",
            className: "PHPhotoLibrary",
            answer: .classMethod(
                Selector(("authorizationStatusForAccessLevel:")),
                .integer(2),
                .withLimited
            ),
            usageDescriptionKeys: ["NSPhotoLibraryUsageDescription"]
        ),
        PermissionProbe(
            subject: "photoLibraryAddOnly",
            className: "PHPhotoLibrary",
            answer: .classMethod(
                Selector(("authorizationStatusForAccessLevel:")),
                .integer(1),
                .withLimited
            ),
            usageDescriptionKeys: ["NSPhotoLibraryAddUsageDescription"]
        ),
        PermissionProbe(
            subject: "contacts",
            className: "CNContactStore",
            answer: .classMethod(
                Selector(("authorizationStatusForEntityType:")),
                .integer(0),
                .withLimited
            ),
            usageDescriptionKeys: ["NSContactsUsageDescription"]
        ),
        PermissionProbe(
            subject: "calendar",
            className: "EKEventStore",
            answer: .classMethod(
                Selector(("authorizationStatusForEntityType:")),
                .integer(0),
                .eventKit
            ),
            usageDescriptionKeys: [
                "NSCalendarsFullAccessUsageDescription",
                "NSCalendarsWriteOnlyAccessUsageDescription",
                "NSCalendarsUsageDescription",
            ]
        ),
        PermissionProbe(
            subject: "reminders",
            className: "EKEventStore",
            answer: .classMethod(
                Selector(("authorizationStatusForEntityType:")),
                .integer(1),
                .eventKit
            ),
            usageDescriptionKeys: [
                "NSRemindersFullAccessUsageDescription",
                "NSRemindersUsageDescription",
            ]
        ),
        PermissionProbe(
            subject: "tracking",
            className: "ATTrackingManager",
            answer: .classMethod(
                Selector(("trackingAuthorizationStatus")),
                .none,
                .standard
            ),
            usageDescriptionKeys: ["NSUserTrackingUsageDescription"]
        ),
        PermissionProbe(
            subject: "speechRecognition",
            className: "SFSpeechRecognizer",
            answer: .classMethod(
                Selector(("authorizationStatus")),
                .none,
                .deniedBeforeRestricted
            ),
            usageDescriptionKeys: ["NSSpeechRecognitionUsageDescription"]
        ),
        PermissionProbe(
            subject: "motionActivity",
            className: "CMMotionActivityManager",
            answer: .classMethod(Selector(("authorizationStatus")), .none, .standard),
            usageDescriptionKeys: ["NSMotionUsageDescription"]
        ),
        // Class property only — a `CBCentralManager` instance would raise the Bluetooth prompt.
        PermissionProbe(
            subject: "bluetooth",
            className: "CBManager",
            answer: .classMethod(Selector(("authorization")), .none, .standard),
            usageDescriptionKeys: ["NSBluetoothAlwaysUsageDescription"]
        ),
        PermissionProbe(
            subject: "mediaLibrary",
            className: "MPMediaLibrary",
            answer: .classMethod(
                Selector(("authorizationStatus")),
                .none,
                .deniedBeforeRestricted
            ),
            usageDescriptionKeys: ["NSAppleMusicUsageDescription"]
        ),
        PermissionProbe(
            subject: "health",
            className: "HKHealthStore",
            answer: .unknowable(
                "read authorization is indistinguishable from absent data"
            ),
            usageDescriptionKeys: [
                "NSHealthShareUsageDescription",
                "NSHealthUpdateUsageDescription",
            ]
        ),
    ]

    let subject: String
    let className: String
    let answer: Answer
    let usageDescriptionKeys: [String]
}

/// What one probe found; a probe whose class is absent produces no finding at all.
struct PermissionFinding: Equatable {
    let subject: String
    let status: String?
    let unknowableBecause: String?
    let usageDescriptionDeclared: Bool
}

extension PermissionProbe {
    static func findings(in bundle: Bundle = .main) -> [PermissionFinding] {
        all.compactMap { $0.finding(in: bundle) }
    }

    func finding(in bundle: Bundle) -> PermissionFinding? {
        guard let owner = objc_getClass(className) as? AnyClass else {
            return nil
        }

        let declared = usageDescriptionKeys.contains { declares($0, in: bundle) }

        switch answer {
        case .unknowable(let because):
            return PermissionFinding(
                subject: subject,
                status: nil,
                unknowableBecause: because,
                usageDescriptionDeclared: declared
            )
        case .classMethod(let selector, let argument, let vocabulary):
            guard let raw = Self.call(selector, on: owner, with: argument)
            else {
                return nil
            }

            return PermissionFinding(
                subject: subject,
                status: vocabulary.name(of: raw),
                unknowableBecause: nil,
                usageDescriptionDeclared: declared
            )
        }
    }

    private func declares(_ key: String, in bundle: Bundle) -> Bool {
        guard let value = bundle.object(forInfoDictionaryKey: key) else {
            return false
        }
        guard let text = value as? String else {
            return true
        }

        return !text.isEmpty
    }

    /// All status enums are `NSInteger`-width; `ATTrackingManager`'s `NSUInteger` values still fit.
    private static func call(
        _ selector: Selector,
        on owner: AnyClass,
        with argument: Argument
    ) -> Int? {
        guard let method = class_getClassMethod(owner, selector) else {
            return nil
        }

        let implementation = method_getImplementation(method)

        switch argument {
        case .none:
            typealias Call = @convention(c) (AnyClass, Selector) -> Int
            return unsafeBitCast(implementation, to: Call.self)(owner, selector)
        case .integer(let value):
            typealias Call = @convention(c) (AnyClass, Selector, Int) -> Int
            return unsafeBitCast(implementation, to: Call.self)(owner, selector, value)
        case .mediaType(let value):
            typealias Call = @convention(c) (AnyClass, Selector, NSString) -> Int
            return unsafeBitCast(implementation, to: Call.self)(
                owner,
                selector,
                value as NSString
            )
        }
    }
}

extension PermissionFinding {
    func write(into out: inout Readings) {
        out.put(.permissionSubject(subject))
        out.put(.usageDescriptionDeclared(usageDescriptionDeclared))
        if let status {
            out.put(.authorizationStatus(status))
        }
        if let unknowableBecause {
            out.put(.mechanismStatus("unknowable: \(unknowableBecause)"))
        }
    }
}

/// Pairs status with the usage-description key: `notDetermined` with none declared crashes on ask.
final class PermissionStatus: Snapshotable, PlainInstrument {
    static let id: InstrumentID = .permissionStatus

    init() {}

    static func write(_ findings: [PermissionFinding], into out: inout Readings) {
        guard let first = findings.first else {
            out
                .put(
                    .mechanismStatus(
                        "no permission-gated framework is linked into this app"
                    )
                )
            return
        }

        first.write(into: &out)
        for finding in findings.dropFirst() {
            out.also(out.entity) { sibling in finding.write(into: &sibling) }
        }
    }

    func reading(_ out: inout Readings) {
        Self.write(PermissionProbe.findings(), into: &out)
    }
}
