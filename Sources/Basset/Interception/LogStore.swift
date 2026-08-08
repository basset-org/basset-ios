import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// What an Apple framework said inside this process. `OSLogStore`'s
/// `.currentProcessIdentifier` scope is process-wide rather than subsystem-wide,
/// so an app reads the logging of every framework running inside it — which is
/// how SwiftUI's runtime issues become observable without a debugger.
///
/// Two limits are structural rather than incidental, and instruments built on
/// this have to carry them: a record holds no backtrace, so it says which rule
/// broke and when but never where; and the store is scoped to the current
/// launch, so nothing survives the process that wrote it.
public struct LogRecord: Sendable, Hashable {
    /// Apple's levels, named here so nothing outside this file needs `OSLog`.
    /// Severity is what separates a diagnostic from a framework's ordinary
    /// chatter within the same subsystem, and it is more durable than a category
    /// allow-list.
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

    /// What this record says, without when it was said. Two faults from the same
    /// rule are one finding with a count, not two findings.
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
    case read([LogRecord])
    case unavailable(String)
}

/// Drains new entries on each call, from wherever the last call stopped.
/// Re-reading from the beginning every time would grow with uptime, and the
/// wall-clock cost of enumerating a busy store on a device is not yet measured.
public final class LogStoreReader: @unchecked Sendable {
    /// Enough to describe a burst without letting one flush spend the request's
    /// whole reading budget. A storm reports a high count on a few subjects
    /// rather than a long tail of near-identical ones.
    public static let defaultCeiling = 256

    private let subsystems: [String]
    private let ceiling: Int
    private let watermark: Mutex<Date>

    public init(
        subsystems: [String],
        since: Date = Date(),
        ceiling: Int = defaultCeiling
    ) {
        self.subsystems = subsystems
        self.ceiling = ceiling
        watermark = .init(since)
    }

    private static func entries(
        subsystems: [String],
        since: Date,
        ceiling: Int
    ) -> LogStoreOutcome {
        #if canImport(OSLog)
        guard #available(iOS 15.0, macOS 12.0, tvOS 15.0, *) else {
            return .unavailable("OSLogStore needs iOS 15")
        }

        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            // No subsystems named means every subsystem in the process, which is
            // what the `log` domain reads. An empty `IN` list matches nothing, so
            // the predicate has to be absent rather than empty — the difference
            // between "everything" and "silence" is one nil.
            let predicate = subsystems.isEmpty
                ? nil
                : NSPredicate(format: "subsystem IN %@", subsystems)
            var records = [LogRecord]()
            for entry in try store.getEntries(at: position, matching: predicate) {
                guard let log = entry as? OSLogEntryLog else {
                    continue
                }
                guard log.date > since else {
                    continue
                }

                records.append(
                    LogRecord(
                        subsystem: log.subsystem,
                        category: log.category,
                        message: log.composedMessage,
                        level: Self.level(of: log),
                        date: log.date
                    )
                )
                if records.count >= ceiling {
                    break
                }
            }
            return .read(records)
        } catch {
            return .unavailable(String(describing: error))
        }
        #else
        return .unavailable("OSLog is not available on this platform")
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

        let outcome = Self.entries(subsystems: subsystems, since: since, ceiling: ceiling)

        if case .read(let records) = outcome {
            // The newest record read, never the wall clock: a store that lags
            // would otherwise have its backlog skipped rather than reported.
            watermark.withLock { $0 = max(records.map(\.date).max() ?? since, since) }
            _ = now
        }
        return outcome
    }
}
