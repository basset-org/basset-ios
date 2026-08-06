import BassetECS
import Foundation
import ObjectiveC

/// What the user actually left switched on for notifications, which
/// "authorized" does not tell you.
///
/// The bug shape this exists for: the app asks whether it is authorized, gets
/// yes, sends a notification, and the user never sees it — because banners are
/// off, or previews are hidden, or Scheduled Delivery is holding it until this
/// evening. Every one of those is `authorizationStatus == .authorized`. The
/// per-setting switches are the answer and almost no app reads them.
///
/// `permissions.status` deliberately leaves notifications alone and points here.
/// It could not have taken this even if the seam were drawn differently: the read
/// is asynchronous, and a snapshot instrument cannot hold a completion handler.
///
/// **Reached by name, so UserNotifications is not linked.** The framework is a
/// permission-gated one, and the rule `permissions` runs on applies unchanged: an
/// app that does not link it is an app that sends no notifications, and that
/// absence is worth more than the reading would have been. Passing a completion
/// handler through the runtime is the only awkward part — a Swift closure bridges
/// to an ObjC block when the signature says `@convention(block)`.
final class NotificationSettings: StreamingInstrument {
    static let id: InstrumentWireID = .notificationSettings
    static let entity = Entity.WireID.notificationSetting

    /// The settings a reader wants, in the order a reader wants them: whether
    /// the app may notify at all, then each way it may be seen.
    static let switches = [
        "alertSetting", "badgeSetting", "soundSetting",
        "lockScreenSetting", "notificationCenterSetting",
        "criticalAlertSetting", "timeSensitiveSetting",
        "scheduledDeliverySetting", "announcementSetting",
    ]

    /// `currentNotificationCenter` raises `NSInternalInconsistencyException`
    /// — *"bundleProxyForCurrentProcess is nil"* — when the process is not an
    /// app, and Swift cannot catch it. An app's own test target linking basset is
    /// exactly such a process, and this instrument activating there would
    /// terminate that test run.
    ///
    /// Not the only one: `permissions` lost its Siri probe to an entitlement
    /// check that raised the same way. A documented, prompt-free status read is
    /// safe only where it has been *observed* to be safe.
    private static var processHasAnAppBundle: Bool {
        let bundle = Bundle.main.bundleURL.pathExtension
        return bundle == "app" || bundle == "appex"
    }

    init() {}

    static func write(_ settings: NotificationSettingsReading, into out: inout Readings) {
        guard let status = settings.authorizationStatus else {
            out.put(.mechanismStatus("unavailable: this app does not use notifications"))
            return
        }

        out.put(.authorizationStatus(status))
        if let style = settings.alertStyle {
            out.put(.alertStyle(style))
        }
        if let previews = settings.previewVisibility {
            out.put(.previewVisibility(previews))
        }

        // Only the switches that are not enabled. An authorized app with
        // everything on is the ordinary case and needs no rows; the finding is
        // always the one the user turned off.
        let withheld = settings.switches.filter { $0.state != "enabled" }
        out.put(.occurrenceCount(UInt64(withheld.count)))
        for setting in withheld {
            out.also(Self.entity) { sibling in
                sibling.put(.notificationSetting(setting.name))
                sibling.put(.settingState(setting.state))
            }
        }
    }

    private static func currentCentre(of center: AnyClass) -> AnyObject? {
        let selector = Selector(("currentNotificationCenter"))
        guard let method = class_getClassMethod(center, selector) else {
            return nil
        }

        typealias Current = @convention(c) (AnyClass, Selector) -> AnyObject?
        return unsafeBitCast(method_getImplementation(method), to: Current.self)(
            center,
            selector
        )
    }

    func observe(_ context: Context) {
        read { settings in
            context.emit { out in
                Self.write(settings, into: &out)
            }
        }
    }

    func stopObserving() {}

    private func read(_ deliver: @escaping (NotificationSettingsReading) -> Void) {
        guard Self.processHasAnAppBundle,
              let center = objc_getClass("UNUserNotificationCenter") as? AnyClass,
              let current = Self.currentCentre(of: center)
        else {
            deliver(NotificationSettingsReading())
            return
        }

        let selector = Selector(("getNotificationSettingsWithCompletionHandler:"))
        guard let method = class_getInstanceMethod(type(of: current), selector) else {
            deliver(NotificationSettingsReading())
            return
        }

        typealias Ask = @convention(c) (
            AnyObject, Selector, @convention(block) (AnyObject?) -> Void
        ) -> Void
        let ask = unsafeBitCast(method_getImplementation(method), to: Ask.self)
        ask(current, selector) { settings in
            deliver(NotificationSettingsReading(settings))
        }
    }
}

/// One `UNNotificationSettings`, read through the runtime.
struct NotificationSettingsReading {
    struct Switch: Equatable {
        let name: String
        let state: String
    }

    let authorizationStatus: String?
    let alertStyle: String?
    let previewVisibility: String?
    let switches: [Switch]

    init(
        authorizationStatus: String? = nil,
        alertStyle: String? = nil,
        previewVisibility: String? = nil,
        switches: [Switch] = []
    ) {
        self.authorizationStatus = authorizationStatus
        self.alertStyle = alertStyle
        self.previewVisibility = previewVisibility
        self.switches = switches
    }

    init(_ settings: AnyObject?) {
        guard let settings else {
            self.init()
            return
        }

        self.init(
            authorizationStatus: Self.read(settings, "authorizationStatus")
                .map(Self.nameOfAuthorization),
            alertStyle: Self.read(settings, "alertStyle").map(Self.nameOfAlertStyle),
            previewVisibility: Self.read(settings, "showPreviewsSetting")
                .map(Self.nameOfPreviews),
            switches: NotificationSettings.switches.compactMap { name in
                Self.read(settings, name).map {
                    Switch(name: Self.subject(of: name), state: Self.nameOfSetting($0))
                }
            }
        )
    }

    /// `notSupported` is the one worth keeping distinct from `disabled`: a
    /// setting the device cannot offer is not a setting the user turned off, and
    /// telling a developer to ask the user to switch something on that does not
    /// exist wastes the one message they get.
    static func nameOfSetting(_ raw: Int) -> String {
        switch raw {
        case 0: "notSupported"
        case 1: "disabled"
        case 2: "enabled"
        default: "unrecognised(\(raw))"
        }
    }

    static func nameOfAuthorization(_ raw: Int) -> String {
        switch raw {
        case 0: "notDetermined"
        case 1: "denied"
        case 2: "authorized"
        case 3: "provisional"
        case 4: "ephemeral"
        default: "unrecognised(\(raw))"
        }
    }

    static func nameOfAlertStyle(_ raw: Int) -> String {
        switch raw {
        case 0: "none"
        case 1: "banner"
        case 2: "alert"
        default: "unrecognised(\(raw))"
        }
    }

    static func nameOfPreviews(_ raw: Int) -> String {
        switch raw {
        case 0: "always"
        case 1: "whenAuthenticated"
        case 2: "never"
        default: "unrecognised(\(raw))"
        }
    }

    private static func read(_ settings: AnyObject, _ key: String) -> Int? {
        guard settings.responds(to: Selector((key))) else {
            return nil
        }

        return (settings.value(forKey: key) as? NSNumber)?.intValue
    }

    /// `alertSetting` reads as `alert`. The suffix is the API's word for "this
    /// is a setting", which every row here already is.
    private static func subject(of key: String) -> String {
        key.hasSuffix("Setting") ? String(key.dropLast("Setting".count)) : key
    }
}
