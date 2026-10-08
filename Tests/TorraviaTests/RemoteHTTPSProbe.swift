@testable import TorraviaSearchCore
import Foundation
import Network
import Security

/// Confines handshake completion and timeout to one queue.
nonisolated final class RemoteHTTPSProbe: @unchecked Sendable {
    enum Result { case connected, rejected, timedOut }
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "TorraviaTests.TLSProbe")
    private var completed = false

    init(port: NWEndpoint.Port, version: tls_protocol_version_t) {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, version)
        sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, version)
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, "localhost")
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let root = SecCertificateCreateWithData(nil, RemoteHTTPSFixture.rootCertificate as CFData),
                  SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustSetVerifyDate(trust, RemoteHTTPSFixture.verificationDate as CFDate) == errSecSuccess else {
                complete(false)
                return
            }
            complete(SecTrustEvaluateWithError(trust, nil))
        }, queue)
        connection = NWConnection(host: "127.0.0.1", port: port, using: NWParameters(tls: options, tcp: .init()))
    }

    func run() async -> Result {
        await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: finish(.connected, continuation: continuation)
                case .failed: finish(.rejected, continuation: continuation)
                case .waiting(let error):
                    // Network framework may retry a failed TLS negotiation.
                    if case .tls = error { finish(.rejected, continuation: continuation) }
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 3) { [self] in finish(.timedOut, continuation: continuation) }
            connection.start(queue: queue)
        }
    }

    private func finish(_ result: Result, continuation: CheckedContinuation<Result, Never>) {
        guard !completed else { return }
        completed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: result)
    }
}
