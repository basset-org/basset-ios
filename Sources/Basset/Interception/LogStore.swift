import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// What an Apple framework logged inside this process — process-wide, every linked SDK.
public struct LogRecord: Sendable, Hashable {
    /// Apple's log levels, named here so nothing outside this file needs to import OSLog.
    public enum Level: String, Sendable {
        case undefined
        case debug
        case info
        case notice
        case error
        case fault

        public var isDiagnostic: Bool {
            self == .error || self == .fault
        }
    }

    public let subsystem: String
    public let category: String
    public let message: String
    public let level: Level
    public let date: Date

    /// What this record says, without when — two faults from one rule are one finding.
    public var subject: some Hashable {
        [subsystem, category, message]
    }

    public init(
        subsystem: String,
        category: String,
        message: String,
        level: Level = .fault,
        date: Date
    ) {
        self.subsystem = subsystem
        self.category = category
        self.message = message
        self.level = level
        self.date = date
    }
}

public enum LogStoreOutcome: Sendable, Equatable {
    /// `cutShort` when the scan hit its ceiling with entries still unread.
    case read([LogRecord], cutShort: Bool)
    case unavailable(String)
}

/// Drains new entries from wherever the last call stopped, not from the beginning.
public final class LogStoreReader: @unchecked Sendable {
    /// Newest date covers skipped entries too, or backlog would grow with the process.
    private struct Scan {
        var records: [LogRecord] = []
        var cutShort = false
        var newest: Date?
    }

    private enum Scanned {
        case scanned(Scan)
        case refused(String)
    }

    /// Enough to describe a burst without spending the whole reading budget on one flush.
    public static let defaultCeiling = 256

    private let subsystems: [String]
    private let ceiling: Int
    private let admitting: @Sendable (LogRecord) -> Bool
    private let watermark: Mutex<Date>

    /// Applied while scanning, not the result — spends the ceiling on records used.
    public init(
        subsystems: [String],
        since: Date = Date(),
        ceiling: Int = defaultCeiling,
        admitting: @escaping @Sendable (LogRecord) -> Bool = { _ in true }
    ) {
        self.subsystems = subsystems
        self.ceiling = ceiling
        self.admitting = admitting
        watermark = .init(since)
    }

    private static func entries(
        subsystems: [String],
        since: Date,
        ceiling: Int,
        admitting: (LogRecord) -> Bool
    ) -> Scanned {
        #if canImport(OSLog)
        guard #available(iOS 15.0, macOS 12.0, tvOS 15.0, *) else {
            return .refused("OSLogStore needs iOS 15")
        }

        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            // No subsystems means every subsystem — nil predicate, not an empty IN list.
            let predicate = subsystems.isEmpty
                ? nil
                : NSPredicate(format: "subsystem IN %@", subsystems)
            var scan = Scan()
            for entry in try store.getEntries(at: position, matching: predicate) {
                guard let log = entry as? OSLogEntryLog else {
                    continue
                }
                guard log.date > since else {
                    continue
                }

                scan.newest = max(scan.newest ?? log.date, log.date)
                let record = LogRecord(
                    subsystem: log.subsystem,
                    category: log.category,
                    message: log.composedMessage,
                    level: Self.level(of: log),
                    date: log.date
                )
                guard admitting(record) else {
                    continue
                }

                // Ceiling reached only once an admitted record still arrives past it.
                guard scan.records.count < ceiling else {
                    scan.cutShort = true
                    break
                }

                scan.records.append(record)
            }
            return .scanned(scan)
        } catch {
            return .refused(String(describing: error))
        }
        #else
        return .refused("OSLog is not available on this platform")
        #endif
    }

    #if canImport(OSLog)
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, *)
    private static func level(of entry: OSLogEntryLog) -> LogRecord.Level {
        switch entry.level {
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .error: .error
        case .fault: .fault
        case .undefined: .undefined
        @unknown default: .undefined
        }
    }
    #endif

    public func drain(now: Date = Date()) -> LogStoreOutcome {
        let since = watermark.withLock { $0 }
        let scanned = Self.entries(
            subsystems: subsystems,
            since: since,
            ceiling: ceiling,
            admitting: admitting
        )

        switch scanned {
        case .refused(let reason):
            return .unavailable(reason)
        case .scanned(let scan):
            // Newest seen, not wall clock, or a lagging store skips its own backlog.
            watermark.withLock { $0 = max(scan.newest ?? since, since) }
            _ = now
            return .read(scan.records, cutShort: scan.cutShort)
        }
    }
}
