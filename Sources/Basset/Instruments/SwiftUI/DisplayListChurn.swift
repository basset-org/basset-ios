import BassetECS
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// How much of SwiftUI's rendered output is actually changing.
///
/// `swiftui.host.updates` says the hosting view laid out; this says whether
/// anything came of it. A screen laying out sixty times a second while its
/// display list never changes is a re-render loop producing no pixels, which is
/// the shape of the bug and not merely its cost.
///
/// **Read the item count before the change count.** `List` and the other
/// collection-backed containers render their rows through UIKit cells, so the
/// display list at the hosting view holds roughly one item and does not move when
/// row content changes — a host laying out 2023 times a second with the seed
/// fixed looks exactly like a re-render loop and is not one. An item count near
/// one means the screen draws through UIKit, and `uikit.view.layoutPass` is the
/// answer for those.
///
/// **Tier-3 mechanism: it fails to silence.** The renderer is reached by walking
/// property names through `Mirror`, and SwiftUI has moved it twice — `renderer`,
/// then `_base.renderer`, then `_base.viewGraph.renderer`. A rename returns nil
/// rather than raising, so an instrument reporting only what it read would look
/// like a quiet app. Every reading carries `mechanismStatus`: *could not read* is
/// a different answer from *nothing changed*.
final class DisplayListChurn: StreamingInstrument {
    private struct Sample: Equatable {
        let itemCount: Int
        let seed: UInt32?
        let fingerprint: Int
    }

    static let id: InstrumentWireID = .swiftUIDisplayListChurn
    static let entity = Entity.WireID.swiftUIDisplayList

    /// Four times a second, over at most four hosts. `Mirror` is not free and
    /// this runs on the main queue; a sample rate that competed with the render
    /// loop would change what it measures.
    ///
    /// The change count therefore saturates: it counts samples that differed, so
    /// a busy second reports four however busy it was. The seed is the
    /// quantitative measure — a re-render storm advances it by thousands a second
    /// where identity churn advances it by hundreds, and both report four changes.
    private static let sampleInterval = 0.25
    private static let hostCeiling = 4

    private let lock: NSLock = .init()
    private var lastSample: [ObjectIdentifier: Sample] = [:]
    private var changes: UInt64 = 0
    private var latest: Sample?
    private var generation: String?
    private var status = "not sampled yet"
    private var sampler: DispatchSourceTimer?

    #if canImport(UIKit)
    private let hosts: WeakRegistry<UIViewController> = .init()
    #endif

    init() {}

    func observe(_ context: Context) {
        #if canImport(UIKit)
        _ = context.swizzle.after(
            UIViewController.self,
            #selector(UIViewController.viewDidAppear(_:))
        ) { [weak self] (receiver, _: Bool) in
            guard SwiftUIHost.kind(of: receiver) != nil,
                  let controller = receiver as? UIViewController
            else {
                return
            }

            self?.hosts.add(controller)
        }

        // On the main queue because the display list is written there: a
        // background sampler would race the render it is describing. Between
        // run-loop turns rather than inside a layout hook — reading a view tree
        // from a swizzled layout call stack induces AttributeGraph cycles.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.sampleInterval,
            repeating: Self.sampleInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self, context.isActive else {
                return
            }

            sample()
        }
        timer.activate()
        sampler = timer

        context.flush(every: .seconds(1)) { [weak self] out, window in
            guard let self else {
                return
            }

            lock.lock()
            let reported = (
                status: status,
                generation: generation,
                latest: latest,
                changes: changes,
                hosts: UInt32(hosts.count)
            )
            changes = 0
            lock.unlock()

            out.put(.windowNanoseconds(window.nanoseconds))
            out.put(.mechanismStatus(reported.status))
            out.put(.hostCount(reported.hosts))
            if let generation = reported.generation {
                out.put(.ivarPathGeneration(generation))
            }
            if let latest = reported.latest {
                out.put(.displayListItemCount(UInt32(latest.itemCount)))
                if let seed = latest.seed {
                    out.put(.displayListSeed(seed))
                }
            }
            out.put(.displayListChangeCount(reported.changes))
        }
        #endif
    }

    func stopObserving() {
        sampler?.cancel()
        sampler = nil
        lock.lock()
        lastSample.removeAll()
        changes = 0
        latest = nil
        generation = nil
        status = "not sampled yet"
        lock.unlock()
    }

    #if canImport(UIKit)
    private func sample() {
        let live = hosts.all.prefix(Self.hostCeiling)
        guard !live.isEmpty else {
            record(status: "no swiftui host on screen")
            return
        }

        for controller in live {
            switch SwiftUIReflection.renderer(of: controller.viewIfLoaded) {
            case .noHostingView:
                record(status: "host has no view loaded")
            case .pathDeadEnded(let generation, let step):
                // The loud half of failing open: the reading says the mechanism
                // did not reach, not that nothing happened.
                record(status: "renderer unreachable at \(generation):\(step)")
            case .reached(let renderer, let generation):
                guard let shape = SwiftUIReflection.displayList(in: renderer) else {
                    record(status: "renderer reached, no display list under it")
                    continue
                }

                note(
                    Sample(
                        itemCount: shape.itemCount,
                        seed: shape.seed,
                        fingerprint: shape.fingerprint
                    ),
                    for: ObjectIdentifier(controller),
                    generation: generation
                )
            }
        }
    }

    private func note(_ sample: Sample, for key: ObjectIdentifier, generation: String) {
        lock.lock()
        if let previous = lastSample[key], previous != sample {
            changes += 1
        }
        lastSample[key] = sample
        latest = sample
        self.generation = generation
        status = "ok"
        lock.unlock()
    }

    private func record(status: String) {
        lock.lock()
        self.status = status
        lock.unlock()
    }
    #endif
}
