import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// State at SIGKILL, in a mapped file — the kernel flushes it; UserDefaults can lose it.
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
        static let bootTime = 96
        static let isSimulator = 104
        static let debuggerAttached = 105
        static let osVersionLength = 106
        static let osVersion = 107
        static let osVersionCapacity = 30
    }

    static let magic: UInt32 = 0x42525231
    static let version: UInt16 = 2
    static let size = 137
    /// A caller comparing a live version string against a stored one truncates to this too.
    static let appVersionCapacity = 30

    var launchId: UInt64 = 0
    var startedAtMicroseconds: UInt64 = 0
    var recordedAtMicroseconds: UInt64 = 0
    var memoryUsedBytes: UInt64 = 0
    /// Zero means the kernel did not answer, not that no memory was left.
    var memoryAvailableBytes: UInt64 = 0
    /// How long the main thread went without reaching idle; zero means it was answering.
    var mainUnresponsiveNanoseconds: UInt64 = 0
    var pressureRecordedAtMicroseconds: UInt64 = 0
    var appState: AppState = .unknown
    var pressureLevel: PressureLevel = .unknown
    var cleanExit = false
    var appVersion = ""
    /// The boot that was active when this run started — a different one next launch means a
    /// reboot happened, not a crash.
    var bootTimeMicroseconds: UInt64 = 0
    var isSimulator = false
    /// Refreshed on every stamp, unlike the boot or app version — a debugger can attach mid-run.
    var debuggerAttached = false
    var osVersion = ""

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
        if length > 0, length <= appVersionCapacity {
            let text = UnsafeRawBufferPointer(
                start: bytes.advanced(by: Offset.appVersion),
                count: length
            )
            record.appVersion = String(decoding: text, as: UTF8.self)
        }

        record.bootTimeMicroseconds = bytes.loadUnaligned(
            fromByteOffset: Offset.bootTime,
            as: UInt64.self
        )
        record.isSimulator = bytes.loadUnaligned(
            fromByteOffset: Offset.isSimulator,
            as: UInt8.self
        ) != 0
        record.debuggerAttached = bytes.loadUnaligned(
            fromByteOffset: Offset.debuggerAttached,
            as: UInt8.self
        ) != 0

        let osLength = Int(bytes.loadUnaligned(
            fromByteOffset: Offset.osVersionLength,
            as: UInt8.self
        ))
        if osLength > 0, osLength <= Offset.osVersionCapacity {
            let text = UnsafeRawBufferPointer(
                start: bytes.advanced(by: Offset.osVersion),
                count: osLength
            )
            record.osVersion = String(decoding: text, as: UTF8.self)
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

        let text = Array(appVersion.utf8.prefix(Self.appVersionCapacity))
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

        bytes.storeBytes(
            of: bootTimeMicroseconds,
            toByteOffset: Offset.bootTime,
            as: UInt64.self
        )
        bytes.storeBytes(
            of: isSimulator ? 1 : 0,
            toByteOffset: Offset.isSimulator,
            as: UInt8.self
        )
        bytes.storeBytes(
            of: debuggerAttached ? 1 : 0,
            toByteOffset: Offset.debuggerAttached,
            as: UInt8.self
        )

        let osText = Array(osVersion.utf8.prefix(Offset.osVersionCapacity))
        bytes.storeBytes(
            of: UInt8(osText.count),
            toByteOffset: Offset.osVersionLength,
            as: UInt8.self
        )
        for (index, byte) in osText.enumerated() {
            bytes.storeBytes(
                of: byte,
                toByteOffset: Offset.osVersion + index,
                as: UInt8.self
            )
        }
    }
}

/// One mapped file per app container, replaced by each launch that opens it.
final class RunRecordFile: @unchecked Sendable {
    /// Previous run's record, read before this run overwrote it; nil if there was none.
    let previous: RunRecord?

    private let bytes: UnsafeMutableRawPointer
    private let descriptor: Int32
    private let guarded: Mutex<RunRecord>

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
        guarded = .init(launch)
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

    /// Under a lock — guards this process's consistency, not a write killed mid-flight.
    func stamp(_ update: (inout RunRecord) -> Void) {
        guarded.withLock { record in
            update(&record)
            record.encode(into: bytes)
        }
    }
}
