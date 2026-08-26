import Darwin

/// Return addresses of whoever called into a chokepoint, innermost first.
///
/// Unlike `ThreadWalker`, nothing is suspended: this runs on the calling thread inside
/// the hook that just fired, so the frames wanted are already the live stack. It is only
/// safe where the chokepoint is cold — object creation, delegate assignment — never on a
/// path that runs per frame or per touch.
public enum CallerStack {
    /// Deeper than this and the frames left are the app's start-up, not its caller.
    public static let maxFrames = 32

    /// `backtrace` itself, `here()`, and the hook that called it are never the caller.
    private static let skipped = 3

    /// Around 235ns for a full 32 frames on an M-series Mac, one allocation for the
    /// result. The scratch buffer is stack memory: a heap one measured 340ns.
    public static func here() -> [UInt64] {
        withUnsafeTemporaryAllocation(
            of: UnsafeMutableRawPointer?.self,
            capacity: maxFrames + skipped
        ) { scratch in
            guard let base = scratch.baseAddress else {
                return []
            }

            let taken = Int(backtrace(base, Int32(scratch.count)))
            guard taken > skipped else {
                return []
            }

            var frames = [UInt64]()
            frames.reserveCapacity(taken - skipped)
            for index in skipped ..< taken {
                frames.append(UInt64(UInt(bitPattern: scratch[index])))
            }
            return frames
        }
    }

    /// Only the frames inside images the app shipped.
    ///
    /// The OS frames between an app's own say nothing about who called, and resolving them
    /// needs device-support symbols for that exact build, which a reader rarely holds. Kept
    /// out of `here`: this walks the mapped image spans, which the chokepoint capture must
    /// not pay for. A stack of what a thread is *doing* wants every frame and skips this.
    static func shipped(_ frames: [UInt64]) -> [UInt64] {
        let directory = BinaryImages.shippedDirectory()
        let images = BinaryImages.covering(frames).filter { $0.isShipped(under: directory) }
        guard !images.isEmpty else {
            return []
        }

        return frames.filter { frame in
            images.contains { $0.loadAddress <= frame && frame < $0.loadAddress + $0.size }
        }
    }
}
