enum QueueLabel {
    static let instrumentRunner = "basset.instruments"
    static let instrumentRunnerFlush = "basset.instruments.flush"
    static let instrumentRunnerExpiry = "basset.instruments.expiry"
    static let http2 = "basset.http2"
    static let networkPath = "basset.path"
    static let mainThreadHang = "basset.hang"
    static let stackSampler = "basset.stacks"
    static let runRecordStamp = "basset.runrecord"

    static func quic(requestId: UInt64) -> String {
        "basset.quic.\(requestId)"
    }

    static func flush(instrument: String) -> String {
        "\(instrumentRunnerFlush).\(instrument)"
    }
}
