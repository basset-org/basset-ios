@testable import Basset
import Foundation
import Testing

/// Same suite as `DeliveryTests`: both drive `StubbedResponses`, a shared singleton that
/// two suites running concurrently would step on each other's planned answers through.
extension DeliveryTests {
    /// A batch still waiting on retry is written to disk, not just held in memory.
    @Test func abatchHeldForRetryIsPersistedToDisk() async {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let requestId: UInt64 = 42
        StubbedResponses.reset([(nil, true)])
        let channel = stubbedChannel(requestId: requestId, backlogDirectory: directory)
        channel.send(Data([1, 2, 3]))

        #expect(await eventually {
            !PersistedBacklog.load(for: requestId, in: directory).isEmpty
        })
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
    }

    /// A reconnect is worth an immediate try rather than waiting out whatever backoff is left.
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
