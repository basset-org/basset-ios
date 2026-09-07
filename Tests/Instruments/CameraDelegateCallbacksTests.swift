@testable import Basset
import Testing

struct CameraDelegateCallbacksTests {
    @Test func everyMethodDeclaresAsManyObjectsAsItsSelectorTakes() {
        for owner in CameraDelegateCallbacks.owners {
            for method in owner.methods {
                let colons = method.selector.filter { $0 == ":" }.count
                #expect(colons == method.objects, "\(method.selector)")
            }
        }
    }

    @Test func theCallbacksThatHandOverAPhotoOrAFileAreNeverDefined() {
        let handing = [
            "captureOutput:didFinishProcessingPhoto:error:",
            "captureOutput:didFinishCapturingDeferredPhotoProxy:error:",
            "captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:",
            "captureOutput:didOutputSampleBuffer:fromConnection:",
        ]
        for owner in CameraDelegateCallbacks.owners {
            for method in owner.methods where handing.contains(method.selector) {
                #expect(!method.definedWhenAbsent, "\(method.selector)")
            }
        }
    }

    @Test func slotsAreThreePerMethodAndNeverOverlap() {
        let bases = CameraDelegateCallbacks.slotBases.flatMap(\.self)
        #expect(Set(bases).count == bases.count)
        #expect(bases.max().map { $0 + 3 } == CameraDelegateCallbacks.tallySlots)
    }

    @Test func everyPhotoStageKnowsWhereItsIdLives() {
        let photo = CameraDelegateCallbacks.owners.first { $0.className == "AVCapturePhotoOutput" }
        #expect(photo?.methods.allSatisfy(\.isPhotoStage) == true)
    }
}
