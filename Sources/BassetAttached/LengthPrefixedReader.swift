import Foundation

#if DEBUG
/// Desired state arrives length-prefixed because a socket hands over whatever
/// happened to arrive: one document can span two reads and two can share one.
/// Readings go the other way needing no framing, since a frame already begins with
/// its own length.
struct LengthPrefixedReader {
    /// A desired state is a short document. A length past this is a caller that has
    /// lost sync rather than a large request, and buffering it would be the bug.
    static let mostBytes = 1 << 20

    private(set) var buffered: Data = .init()

    mutating func append(_ chunk: Data) {
        buffered.append(chunk)
    }

    mutating func next() throws -> Data? {
        guard buffered.count >= 4 else {
            return nil
        }

        let length = buffered.prefix(4).reduce(Int(0)) { ($0 << 8) | Int($1) }
        guard length <= Self.mostBytes else {
            throw BassetAttached.Failure.documentTooLong(length)
        }
        guard buffered.count >= 4 + length else {
            return nil
        }

        let document = buffered.dropFirst(4).prefix(length)
        buffered.removeFirst(4 + length)
        return Data(document)
    }
}
#endif
