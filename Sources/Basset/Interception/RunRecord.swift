import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What the previous run of this app was doing when it stopped existing.
///
/// A process killed by jetsam or the watchdog gets `SIGKILL`. No handler runs,
/// no `deinit` fires, nothing in the app observes its own death — so the only
/// way to learn anything is to have already written it down. This is that
/// writing-down: a fixed-size record kept in a memory-mapped file, stamped while
/// the app runs and read by the launch that follows.
///
/// **`UserDefaults` cannot do this job.** Its writes are flushed on the
/// framework's schedule, so the last one before a `SIGKILL` is exactly the one
/// that can be lost — the write this record exists to preserve. Stores into a
/// mapped page are flushed by the kernel independently of the process, so they
/// survive a kill the process never sees coming.
///
/// **The layout is byte offsets rather than a Swift struct**, because the run
/// that writes a record and the run that reads it can be two different builds of
/// the app: the user updated between them. Swift guarantees nothing about struct
/// layout across compilations, so the format is stated here explicitly, and
/// `magic` plus `version` reject anything that is not it.
///
/// Every field is written as a single aligned store, which arm64 does not tear.
/// A record can still be internally inconsistent — a kill can land between two
/// fields — so nothing here is derived from two fields agreeing.
struct RunRecord: Equatable {
    enum AppState: UInt8 {
        case unknown = 0
        case foreground = 1
        case background = 2
    }

    enum PressureLevel: UInt8 {
        case unknown = 0
        case normal = 1
        case warning = 2
        case critical = 3
    }

    private enum Offset {
        static let magic = 0
        static let version = 4
        static let appState = 6
        static let pressureLevel = 7
        static let launchId = 8
        static let startedAt = 16
        static let recordedAt = 24
        static let memoryUsed = 32
        static let memoryAvailable = 40
        static let mainUnresponsive = 48
        static let pressureRecordedAt = 56
        static let cleanExit = 64
        static let appVersionLength = 65
        static let appVersion = 66
        static let appVersionCapacity = 30
    }

    static let magic: UInt32 = 0x42525231
    static let version: UInt16 = 1
    static let size = 96

    var launchId: UInt64 = 0
    var startedAtMicroseconds: UInt64 = 0
    var recordedAtMicroseconds: UInt64 = 0
    var memoryUsedBytes: UInt64 = 0
    /// Zero means the kernel did not answer, not that no memory was left.
    var memoryAvailableBytes: UInt64 = 0
    /// How long the main thread had gone without reaching idle. Zero is a main
    /// thread that was answering.
    var mainUnresponsiveNanoseconds: UInt64 = 0
    var pressureRecordedAtMicroseconds: UInt64 = 0
    var appState: AppState = .unknown
    var pressureLevel: PressureLevel = .unknown
    var cleanExit = false
    var appVersion = ""

    static func decode(_ bytes: UnsafeRawPointer) -> RunRecord? {
        guard bytes.loadUnaligned(fromByteOffset: Offset.magic, as: UInt32.self) == magic,
              bytes
              .loadUnaligned(fromByteOffset: Offset.version, as: UInt16.self) == version
        else {
            return nil
        }

        var record = RunRecord()
        record.launchId = bytes.loadUnaligned(
            fromByteOffset: Offset.launchId,
            as: UInt64.self
        )
        record.startedAtMicroseconds = bytes.loadUnaligned(
            fromByteOffset: Offset.startedAt,
            as: UInt64.self
        )
        record.recordedAtMicroseconds = bytes.loadUnaligned(
            fromByteOffset: Offset.recordedAt,
            as: UInt64.self
        )
        record.memoryUsedBytes = bytes.loadUnaligned(
            fromByteOffset: Offset.memoryUsed,
            as: UInt64.self
        )
        record.memoryAvailableBytes = bytes.loadUnaligned(
            fromByteOffset: Offset.memoryAvailable,
            as: UInt64.self
        )
        record.mainUnresponsiveNanoseconds = bytes.loadUnaligned(
            fromByteOffset: Offset.mainUnresponsive,
            as: UInt64.self
        )
        record.pressureRecordedAtMicroseconds = bytes.loadUnaligned(
            fromByteOffset: Offset.pressureRecordedAt,
            as: UInt64.self
        )
        record.appState = AppState(
            rawValue: bytes.loadUnaligned(fromByteOffset: Offset.appState, as: UInt8.self)
        ) ?? .unknown
        record.pressureLevel = PressureLevel(
            rawValue: bytes.loadUnaligned(
                fromByteOffset: Offset.pressureLevel,
                as: UInt8.self
            )
        ) ?? .unknown
        record.cleanExit = bytes.loadUnaligned(
            fromByteOffset: Offset.cleanExit,
            as: UInt8.self
        ) != 0

        let length = Int(bytes.loadUnaligned(
            fromByteOffset: Offset.appVersionLength,
            as: UInt8.self
        ))
        if length > 0, length <= Offset.appVersionCapacity {
            let text = UnsafeRawBufferPointer(
                start: bytes.advanced(by: Offset.appVersion),
                count: length
            )
            record.appVersion = String(decoding: text, as: UTF8.self)
        }
        return record
    }

    func encode(into bytes: UnsafeMutableRawPointer) {
        bytes.storeBytes(of: Self.magic, toByteOffset: Offset.magic, as: UInt32.self)
        bytes.storeBytes(of: Self.version, toByteOffset: Offset.version, as: UInt16.self)
        bytes.storeBytes(
            of: appState.rawValue,
            toByteOffset: Offset.appState,
            as: UInt8.self
        )
        bytes.storeBytes(
            of: pressureLevel.rawValue,
            toByteOffset: Offset.pressureLevel,
            as: UInt8.self
        )
        bytes.storeBytes(of: launchId, toByteOffset: Offset.launchId, as: UInt64.self)
        bytes.storeBytes(
            of: startedAtMicroseconds,
            toByteOffset: Offset.startedAt,
            as: UInt64.self
        )
        bytes.storeBytes(
            of: recordedAtMicroseconds,
            toByteOffset: Offset.recordedAt,
            as: UInt64.self
        )
        bytes.storeBytes(
            of: memoryUsedBytes,
            toByteOffset: Offset.memoryUsed,
            as: UInt64.self
        )
        bytes.storeBytes(
            of: memoryAvailableBytes,
            toByteOffset: Offset.memoryAvailable,
            as: UInt64.self
        )
        bytes.storeBytes(
            of: mainUnresponsiveNanoseconds,
            toByteOffset: Offset.mainUnresponsive,
            as: UInt64.self
        )
        bytes.storeBytes(
            of: pressureRecordedAtMicroseconds,
            toByteOffset: Offset.pressureRecordedAt,
            as: UInt64.self
        )
        bytes.storeBytes(
            of: cleanExit ? 1 : 0,
            toByteOffset: Offset.cleanExit,
            as: UInt8.self
        )

        let text = Array(appVersion.utf8.prefix(Offset.appVersionCapacity))
        bytes.storeBytes(
            of: UInt8(text.count),
            toByteOffset: Offset.appVersionLength,
            as: UInt8.self
        )
        for (index, byte) in text.enumerated() {
            bytes.storeBytes(
                of: byte,
                toByteOffset: Offset.appVersion + index,
                as: UInt8.self
            )
        }
    }
}

/// The mapped file the record lives in. One per app container, replaced at each
/// launch by the launch that reads it.
final class RunRecordFile: @unchecked Sendable {
    /// The record the *previous* run left behind, read before this run overwrote
    /// it. Nil when there was no previous run, or its record predates this
    /// format.
    let previous: RunRecord?

    private let bytes: UnsafeMutableRawPointer
    private let descriptor: Int32
    private let lock: NSLock = .init()
    private var record: RunRecord

    init?(at url: URL, startedBy launch: RunRecord) {
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            return nil
        }
        guard ftruncate(descriptor, off_t(RunRecord.size)) == 0 else {
            close(descriptor)
            return nil
        }

        let mapped = mmap(
            nil,
            RunRecord.size,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            descriptor,
            0
        )
        guard let mapped, mapped != MAP_FAILED else {
            close(descriptor)
            return nil
        }

        self.descriptor = descriptor
        bytes = mapped
        previous = RunRecord.decode(UnsafeRawPointer(mapped))
        record = launch
        launch.encode(into: mapped)
    }

    deinit {
        munmap(bytes, RunRecord.size)
        close(descriptor)
    }

    static func url(in directory: FileManager
        .SearchPathDirectory = .applicationSupportDirectory)
        -> URL?
    {
        guard let base = FileManager.default
            .urls(for: directory, in: .userDomainMask)
            .first
        else {
            return nil
        }

        let folder = base.appendingPathComponent("basset", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return folder.appendingPathComponent("run-record", isDirectory: false)
    }

    /// Read-modify-write under a lock, because two observers can stamp at once.
    /// The lock guards this process's own consistency; it cannot make the record
    /// survive a kill mid-update, which is why nothing derived from it needs two
    /// fields to agree.
    func stamp(_ update: (inout RunRecord) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        update(&record)
        record.encode(into: bytes)
    }
}
