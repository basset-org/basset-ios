@testable import Basset
import Foundation
import Testing

struct LogMessagesTests {
    @Test func appLinesAreInAtInfoAndAboveAndDebugIsNot() {
        #expect(LogMessages.admits(record("com.j.cameras", level: .info), scoped: false))
        #expect(LogMessages.admits(record("com.j.cameras", level: .notice), scoped: false))
        #expect(LogMessages.admits(record("com.j.cameras", level: .fault), scoped: false))
        #expect(!LogMessages.admits(record("com.j.cameras", level: .debug), scoped: false))
        #expect(!LogMessages.admits(record("com.j.cameras", level: .undefined), scoped: false))
    }

    @Test func appleAndUnnamedSubsystemsAreOutUnlessNamed() {
        #expect(!LogMessages.admits(record("com.apple.network", level: .info), scoped: false))
        #expect(!LogMessages.admits(record("", level: .error), scoped: false))
        #expect(LogMessages.admits(record("com.apple.network", level: .info), scoped: true))
    }

    private func record(_ subsystem: String, level: LogRecord.Level) -> LogRecord {
        LogRecord(subsystem: subsystem, category: "c", message: "m", level: level, date: Date())
    }
}
