import Foundation

/// The at_launch requests, kept so the next launch can activate instruments
/// before any network call
struct AtLaunchRequests: @unchecked Sendable {
    let storage: UserDefaults

    private let key = "dev.basset.at-launch-requests"

    init(storage: UserDefaults = .standard) {
        self.storage = storage
    }

    func save(_ requests: [BassetRequest]) {
        let requests = requests.filter(\.atLaunch).map(\.withoutToken)
        guard !requests.isEmpty else {
            storage.removeObject(forKey: key)
            return
        }
        guard let encoded = try? JSONEncoder().encode(requests) else {
            return
        }

        storage.set(encoded, forKey: key)
    }

    func load(at moment: Date = Date()) -> [BassetRequest] {
        guard
            let data = storage.data(forKey: key),
            let decoded = try? JSONDecoder().decode([BassetRequest].self, from: data)
        else {
            return []
        }

        return decoded.filter { $0.isLive(at: moment) }
    }

    func clear() {
        storage.removeObject(forKey: key)
    }
}
