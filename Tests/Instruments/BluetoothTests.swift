@testable import Basset
import Foundation
import ObjectiveC
import Testing

struct CentralStateTests {
    /// Stands in for a `CBCentralManager` by answering the one key that is read.
    private final class ProbeCentral: NSObject {
        @objc let state: Int

        init(state: Int) {
            self.state = state
        }
    }

    private final class ProbeDelegate: NSObject {
        @objc dynamic func centralManagerDidUpdateState(_ central: AnyObject) {}
    }

    private final class EmptyDelegate: NSObject {}

    /// `CBManagerState` shares early values with `CBManagerAuthorization`, then diverges.
    @Test func stateNamesFollowCBManagerStateRatherThanAuthorization() {
        #expect(CentralState.name(ofState: 0) == "unknown")
        #expect(CentralState.name(ofState: 1) == "resetting")
        #expect(CentralState.name(ofState: 2) == "unsupported")
        #expect(CentralState.name(ofState: 3) == "unauthorized")
        #expect(CentralState.name(ofState: 4) == "poweredOff")
        #expect(CentralState.name(ofState: 5) == "poweredOn")
        #expect(CentralState.name(ofState: 9) == "unrecognised(9)")
    }

    /// Three states look identical from inside the app — no peripherals, no error, forever.
    @Test func theThreeSilentFailuresAreDistinctValues() {
        let silent = [2, 3, 4].map(CentralState.name(ofState:))

        #expect(Set(silent).count == 3)
        #expect(silent.allSatisfy { $0 != "poweredOn" })
    }

    /// Reads through the runtime so CoreBluetooth stays unlinked — a manager raises the prompt.
    @Test func theStateIsReadFromWhicheverObjectTheFrameworkPassed() {
        #expect(CentralState.state(of: ProbeCentral(state: 5)) == "poweredOn")
        #expect(CentralState.state(of: ProbeCentral(state: 3)) == "unauthorized")
    }

    /// Answers `unknown` rather than raising — a missing key is an uncatchable ObjC exception.
    @Test func somethingThatIsNotACentralIsSurvived() {
        #expect(CentralState.state(of: NSObject()) == "unknown")
        #expect(CentralState.state(of: nil) == "unknown")
    }

    /// A delegate missing the required callback can't learn its state — readable unswizzled.
    @Test func aDelegateMissingTheRequiredCallbackIsVisible() {
        #expect(class_getInstanceMethod(
            ProbeDelegate.self,
            CentralState.didUpdateState
        ) !=
            nil)
        #expect(class_getInstanceMethod(
            EmptyDelegate.self,
            CentralState.didUpdateState
        ) ==
            nil)
    }
}
