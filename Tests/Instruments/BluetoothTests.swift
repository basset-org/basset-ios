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

    /// `CBManagerState` shares its first values with `CBManagerAuthorization`
    /// and then diverges, so the two must not share a mapping. `permissions`
    /// reports authorization; this reports the manager's own state, and 3 means
    /// different things to each.
    @Test func stateNamesFollowCBManagerStateRatherThanAuthorization() {
        #expect(CentralState.name(ofState: 0) == "unknown")
        #expect(CentralState.name(ofState: 1) == "resetting")
        #expect(CentralState.name(ofState: 2) == "unsupported")
        #expect(CentralState.name(ofState: 3) == "unauthorized")
        #expect(CentralState.name(ofState: 4) == "poweredOff")
        #expect(CentralState.name(ofState: 5) == "poweredOn")
        #expect(CentralState.name(ofState: 9) == "unrecognised(9)")
    }

    /// The three that look identical from inside the app — no peripherals, no
    /// error, forever — and which only this reading tells apart.
    @Test func theThreeSilentFailuresAreDistinctValues() {
        let silent = [2, 3, 4].map(CentralState.name(ofState:))

        #expect(Set(silent).count == 3)
        #expect(silent.allSatisfy { $0 != "poweredOn" })
    }

    /// Read off the central the framework handed over, through the runtime, so
    /// CoreBluetooth is never linked and basset never makes a manager of its own
    /// — making one raises the Bluetooth prompt.
    @Test func theStateIsReadFromWhicheverObjectTheFrameworkPassed() {
        #expect(CentralState.state(of: ProbeCentral(state: 5)) == "poweredOn")
        #expect(CentralState.state(of: ProbeCentral(state: 3)) == "unauthorized")
    }

    /// Anything that is not a central answers `unknown` rather than raising —
    /// `value(forKey:)` on a missing key is the uncatchable ObjC exception that
    /// cost `permissions` its Siri probe.
    @Test func somethingThatIsNotACentralIsSurvived() {
        #expect(CentralState.state(of: NSObject()) == "unknown")
        #expect(CentralState.state(of: nil) == "unknown")
    }

    /// `centralManagerDidUpdateState:` is required by the protocol, so a
    /// delegate class without it cannot learn its own Bluetooth state. The
    /// absence is readable without swizzling anything.
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
