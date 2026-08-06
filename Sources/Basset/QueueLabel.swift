enum QueueLabel {
    static let runtime = "basset.runtime"
    static let runtimeFlush = "basset.runtime.flush"
    static let http2 = "basset.http2"
    static let networkPath = "basset.path"
    static let mainThreadHang = "basset.hang"
    static let runRecordStamp = "basset.runrecord"

    static func quic(requestId: UInt64) -> String {
        "basset.quic.\(requestId)"
    }

    static func flush(instrument: String) -> String {
        "\(runtimeFlush).\(instrument)"
    }
}
