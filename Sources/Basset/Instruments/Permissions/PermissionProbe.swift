import BassetECS
import Foundation

/// One thing the user can allow or refuse, and how to ask the system about it
/// without linking the framework that owns it and without prompting anybody.
///
/// **basset links none of these frameworks.** Linking HealthKit or Contacts to
/// read a status would put them in every app's binary. The class is reached
/// through the ObjC runtime by name instead, and a class that is not there is not
/// a failure — it answers that this app does not use that framework, so no row is
/// emitted.
///
/// That holds for every subject **except camera and microphone**: the camera
/// instruments import AVFoundation unconditionally, so `AVCaptureDevice` is
/// present in any app linking basset whether or not it touches a camera. Their
/// statuses are still true; only the absence heuristic is unavailable, and the
/// usage description in the same row carries that instead. Nothing else basset
/// imports is permission-gated, and an import that was would silently take the
/// same property away from another subject.
///
/// **basset calls no `request*` method, ever.** Requesting without the matching
/// `Info.plist` key terminates the process, which would make the diagnostic tool
/// the outage. Every selector here is a status read that prompts nothing.
struct PermissionProbe {
    /// The status enums are not one enum. Most frameworks number them
    /// notDetermined, restricted, denied, authorized — and Speech and
    /// MediaPlayer swap the middle two, so a reader that assumes one ordering
    /// reports *restricted* for a user who tapped Don't Allow. That is a wrong
    /// answer rather than a missing one, and it is why each probe carries the
    /// spelling its own framework uses.
    enum Vocabulary {
        case standard
        case withLimited
        case deniedBeforeRestricted
        case eventKit

        /// A value past the end is a status this SDK predates. Reported as the
        /// number it was, because naming it after the nearest case we do know
        /// would be a confident wrong answer about what a user chose.
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
        /// HealthKit read authorization is unknowable by design: denied data is
        /// indistinguishable from absent data, so an app cannot learn whether it
        /// was refused. Reported rather than omitted — an absent row would read
        /// as "HealthKit is fine".
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
        // The class property, not the deprecated instance one — and reading it
        // is the only safe question here. Constructing a `CBCentralManager`
        // raises the Bluetooth prompt, which is a visible change to the app.
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

/// What one probe found: the framework is in the app, and this is where it
/// stands. A probe whose class is absent produces no finding at all.
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

    /// The status enums are all `NSInteger`-width, so one return type covers
    /// every probe. `ATTrackingManager` declares `NSUInteger` and the values it
    /// answers with are small enough that the two agree.
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
