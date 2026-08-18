@testable import Basset
import Foundation
import Testing

/// Same suite as `DeliveryTests`: both drive `StubbedResponses`, a shared singleton that
/// two suites running concurrently would step on each other's planned answers through.
extension DeliveryTests {
    /// A crash between "posted" and "answered" must not already have erased the only copy.
    @Test func anInFlightRetryStaysOnDiskUntilItIsAnswered() async {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let requestId: UInt64 = 21
        PersistedBacklog.save(
            [(bytes: Data([5, 5, 5]), frames: 1)],
            for: requestId,
            in: directory
        )

        // Neither an error nor a status: the retry is sent and never answered.
        StubbedResponses.reset([(nil, false)])
        let channel = stubbedChannel(requestId: requestId, backlogDirectory: directory)

        #expect(await eventually { StubbedResponses.seen >= 1 }, "the retry was actually sent")
        #expect(
            !PersistedBacklog.load(for: requestId, in: directory).isEmpty,
            "still on disk while the POST is outstanding, not cleared the moment it's attempted"
        )
        channel.close()
    }

    /// A first attempt is owed to disk exactly like a retry is — it just hasn't failed yet.
    @Test func afirstAttemptStaysOnDiskUntilItIsAnswered() async {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let requestId: UInt64 = 31

        // Neither an error nor a status: the first attempt is sent and never answered.
        StubbedResponses.reset([(nil, false)])
        let channel = stubbedChannel(requestId: requestId, backlogDirectory: directory)
        channel.send(Data([7, 7, 7]))

        #expect(await eventually { StubbedResponses.seen >= 1 }, "the first attempt was sent")
        #expect(
            !PersistedBacklog.load(for: requestId, in: directory).isEmpty,
            "on disk before it's answered, not only after it first fails"
        )
        channel.close()
    }

    /// A batch the 429 just refused must not also be counted through the in-flight sweep.
    @Test func a429DoesNotDoubleCountTheBatchItRefused() async {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let requestId: UInt64 = 45
        PersistedBacklog.save(
            [(bytes: Data([1, 2, 3, 4]), frames: 4)],
            for: requestId,
            in: directory
        )

        StubbedResponses.reset([(429, false)])
        let channel = stubbedChannel(requestId: requestId, backlogDirectory: directory)

        #expect(await eventually { channel.refused == "max_frames" })
        #expect(channel.dropped == 4, "counted once, not once for the batch and once for the sweep")
        channel.close()
    }

    /// What a crash leaves on disk is what the next launch's channel retries on its own.
    @Test func apersistedBacklogIsRetriedWhenTheChannelIsRebuilt() async {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let requestId: UInt64 = 7
        PersistedBacklog.save(
            [(bytes: Data([9, 9, 9]), frames: 1)],
            for: requestId,
            in: directory
        )

        StubbedResponses.reset([(200, false)])
        let channel = stubbedChannel(requestId: requestId, backlogDirectory: directory)

        #expect(await eventually { StubbedResponses.seen >= 1 })
        #expect(await eventually {
            PersistedBacklog.load(for: requestId, in: directory).isEmpty
        })
        #expect(channel.dropped == 0, "nothing the crash left behind was written off")
        channel.close()
    }

    /// Also covers the plain retry case: a real failure holds a batch and persists it — a
    /// reconnect is worth an immediate try after that rather than waiting out the backoff.
    @Test func areconnectRetriesWithoutWaitingForTheBackoff() async {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let requestId: UInt64 = 13
        StubbedResponses.reset([(nil, true)])
        let channel = stubbedChannel(requestId: requestId, backlogDirectory: directory)
        channel.send(Data([1, 2, 3]))
        #expect(await eventually {
            !PersistedBacklog.load(for: requestId, in: directory).isEmpty
        })

        StubbedResponses.reset([(200, false)])
        channel.reconnected()

        // Well under the 1s backoff the failed send just scheduled: only the reconnect explains it.
        #expect(await eventually(within: .milliseconds(300)) { StubbedResponses.seen >= 1 })
        #expect(await eventually {
            PersistedBacklog.load(for: requestId, in: directory).isEmpty
        })
        channel.close()
    }

    /// Cancelled while offline means discard, same as the in-memory buffers upstream.
    @Test func closingATransportDiscardsItsPersistedBacklog() async {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let requestId: UInt64 = 3
        PersistedBacklog.save(
            [(bytes: Data([9]), frames: 1)],
            for: requestId,
            in: directory
        )
        StubbedResponses.reset([(nil, true)])
        let channel = stubbedChannel(requestId: requestId, backlogDirectory: directory)

        channel.close()

        #expect(await eventually {
            PersistedBacklog.load(for: requestId, in: directory).isEmpty
        })
    }

    /// A capture waiting on disk for a retry does not belong in the next iCloud/iTunes backup.
    @Test func aSavedBacklogFileIsExcludedFromBackup() throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let requestId: UInt64 = 51
        PersistedBacklog.save(
            [(bytes: Data([1, 2, 3]), frames: 1)],
            for: requestId,
            in: directory
        )

        let file = directory.appendingPathComponent(String(requestId), isDirectory: false)
        let excluded = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup
        #expect(excluded == true)
    }

    /// A request the process did not resume is gone, whatever it left behind on disk.
    @Test func sweepDiscardsABacklogForARequestThatDidNotResume() {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        PersistedBacklog.save([(bytes: Data([1]), frames: 1)], for: 1, in: directory)
        PersistedBacklog.save([(bytes: Data([2]), frames: 1)], for: 2, in: directory)

        PersistedBacklog.sweep(keeping: [1], in: directory)

        #expect(!PersistedBacklog.load(for: 1, in: directory).isEmpty)
        #expect(PersistedBacklog.load(for: 2, in: directory).isEmpty)
    }
}
