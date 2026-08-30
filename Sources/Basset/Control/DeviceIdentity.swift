import Foundation

#if canImport(UIKit)
import UIKit
#endif

struct DeviceIdentity: Sendable, Equatable {
    let deviceId: String
    let model: String
    let os: String
    let appVersion: String
    let appName: String
    let bundleId: String?
    let buildConfiguration: String
    let deviceKind: String

    static func current(storage: UserDefaults = .standard) -> DeviceIdentity {
        DeviceIdentity(
            deviceId: persistentDeviceId(in: storage),
            model: hardwareModel(),
            os: operatingSystem(),
            appVersion: applicationVersion(),
            appName: applicationName(),
            bundleId: Bundle.main.bundleIdentifier,
            buildConfiguration: compiledConfiguration(),
            deviceKind: targetEnvironment()
        )
    }
}

private func compiledConfiguration() -> String {
    #if DEBUG
    return "debug"
    #else
    return "release"
    #endif
}

private func targetEnvironment() -> String {
    #if targetEnvironment(simulator)
    return "simulator"
    #else
    return "hardware"
    #endif
}

private let deviceIdKey = "dev.basset.device-id"

private func persistentDeviceId(in storage: UserDefaults) -> String {
    if let existing = storage.string(forKey: deviceIdKey), !existing.isEmpty {
        return existing
    }
    let created = UUID().uuidString
    storage.set(created, forKey: deviceIdKey)
    return created
}

private func hardwareModel() -> String {
    let environment = ProcessInfo.processInfo.environment
    if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
        return simulated
    }

    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    guard size > 0 else {
        return "unknown"
    }

    var value = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.machine", &value, &size, nil, 0)
    return String(cString: value)
}

private func operatingSystem() -> String {
    #if canImport(UIKit)
    return UIDevice.current.systemVersion
    #else
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    #endif
}

private func applicationName() -> String {
    let info = Bundle.main.infoDictionary
    return info?["CFBundleDisplayName"] as? String
        ?? info?["CFBundleName"] as? String
        ?? "unknown"
}

private func applicationVersion() -> String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String
    let build = info?["CFBundleVersion"] as? String

    switch (short, build) {
    case (.some(let short), .some(let build)):
        return "\(short) (\(build))"
    case (.some(let short), .none):
        return short
    case (.none, .some(let build)):
        return build
    case (.none, .none):
        return "unknown"
    }
}
