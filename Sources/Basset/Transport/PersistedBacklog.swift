import Foundation

/// A crash mid-outage loses nothing an atomic rename already committed to disk.
enum PersistedBacklog {
    /// Serializes every call: an atomic write's own temp file is invisible to nothing else
    /// here, but a sweep running its directory listing mid-rename would still delete it.
    private static let lock: NSLock = .init()

    static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("basset", isDirectory: true)
            .appendingPathComponent("backlog", isDirectory: true)
    }

    /// One batch on reload regardless of how many were written — batch boundaries are
    /// POST chunking, not meaning, and every frame inside is still independently framed.
    static func load(
        for requestId: UInt64,
        in directory: URL = defaultDirectory()
    ) -> [(bytes: Data, frames: Int)] {
        lock.lock()
        defer { lock.unlock() }

        guard let payload = try? Data(contentsOf: url(for: requestId, in: directory)),
              payload.count > 4
        else {
            return []
        }

        let frames = Int(payload.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard frames > 0 else {
            return []
        }

        return [(bytes: payload.dropFirst(4), frames: frames)]
    }

    static func save(
        _ waiting: [(bytes: Data, frames: Int)],
        for requestId: UInt64,
        in directory: URL = defaultDirectory()
    ) {
        let totalFrames = waiting.reduce(0) { $0 + $1.frames }
        guard totalFrames > 0 else {
            remove(for: requestId, in: directory)
            return
        }

        var payload = Data(count: 4)
        payload.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(totalFrames), as: UInt32.self) }
        waiting.forEach { payload.append($0.bytes) }

        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let target = url(for: requestId, in: directory)
        try? payload.write(
            to: target,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        // The atomic write above replaces the file via a rename, which drops this resource
        // value — it has to be reapplied to the surviving file, not the one that was written.
        excludeFromBackup(target)
    }

    static func remove(for requestId: UInt64, in directory: URL = defaultDirectory()) {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.removeItem(at: url(for: requestId, in: directory))
    }

    /// Mirrors the in-memory rule: a request this process did not resume is gone, not retried.
    static func sweep(keeping live: Set<UInt64>, in directory: URL = defaultDirectory()) {
        lock.lock()
        defer { lock.unlock() }

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else {
            return
        }

        for name in names {
            guard let requestId = UInt64(name), live.contains(requestId) else {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                continue
            }
        }
    }

    private static func excludeFromBackup(_ target: URL) {
        var target = target
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? target.setResourceValues(resourceValues)
    }

    private static func url(for requestId: UInt64, in directory: URL) -> URL {
        directory.appendingPathComponent(String(requestId), isDirectory: false)
    }
}
