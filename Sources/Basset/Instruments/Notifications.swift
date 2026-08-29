import BassetEntityComponent
import Foundation
import ObjectiveC

/// Reached by name so UserNotifications is never linked, matching the rule `permissions` runs on.
final class NotificationSettings: Streamable, PlainInstrument {
    static let id: InstrumentID = .notificationSettings

    static let switches = [
        "alertSetting", "badgeSetting", "soundSetting",
        "lockScreenSetting", "notificationCenterSetting",
        "criticalAlertSetting", "timeSensitiveSetting",
        "scheduledDeliverySetting", "announcementSetting",
    ]

    /// `currentNotificationCenter` raises an uncatchable exception when the process is not an app.
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

        // Only the switches not enabled; an app with everything on needs no rows.
        let withheld = settings.switches.filter { $0.state != "enabled" }
        out.put(.occurrenceCount(UInt64(withheld.count)))
        for setting in withheld {
            out.also(out.entity) { additional in
                additional.put(.notificationSetting(setting.name))
                additional.put(.settingState(setting.state))
            }
        }
    }

    /// Cast to AnyObject so the block heap-allocates; a stack block traps on late completion.
    static func ask(_ receiver: AnyObject,
                    _ selector: Selector,
                    answering deliver: @escaping (AnyObject?) -> Void) -> Bool
    {
        guard let method = class_getInstanceMethod(type(of: receiver), selector)
        else {
            return false
        }

        typealias Ask = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let ask = unsafeBitCast(method_getImplementation(method), to: Ask.self)
        let handler: @convention(block) (AnyObject?) -> Void = { deliver($0) }
        ask(receiver, selector, handler as AnyObject)
        return true
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
            context.emit(.notificationSetting) { out in
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

        let asked = Self.ask(
            current,
            Selector(("getNotificationSettingsWithCompletionHandler:"))
        ) { settings in
            deliver(NotificationSettingsReading(settings))
        }
        if !asked {
            deliver(NotificationSettingsReading())
        }
    }
}

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

    /// `notSupported` stays distinct from `disabled`: unavailable is not the user's choice.
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

    private static func subject(of key: String) -> String {
        key.hasSuffix("Setting") ? String(key.dropLast("Setting".count)) : key
    }
}
