import Foundation
import Network
import Darwin

nonisolated enum RemoteHTTPError: LocalizedError {
    case malformed, tooLarge, unsupportedEncoding, timedOut
    var errorDescription: String? {
        switch self {
        case .malformed: return "Malformed HTTP request."
        case .tooLarge: return "Request exceeds the 8 MiB limit."
        case .unsupportedEncoding: return "Chunked requests are not supported. Send Content-Length."
        case .timedOut: return "Request timed out."
        }
    }
}

nonisolated struct RemoteHTTPRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    nonisolated static let maximumBodySize = 8 * 1024 * 1024

    /// Returns nil until the complete header AND declared body have arrived.
    nonisolated static func parse(_ data: Data) throws -> RemoteHTTPRequest? {
        guard data.count <= maximumBodySize + 16384 else { throw RemoteHTTPError.tooLarge }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16384 { throw RemoteHTTPError.tooLarge }
            return nil
        }
        guard boundary.lowerBound <= 16384,
              let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw RemoteHTTPError.malformed }
        let lines = header.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
              parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"), !parts[1].contains("\\") else { throw RemoteHTTPError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line.first != " ", line.first != "\t" else { throw RemoteHTTPError.malformed }
            let name = String(line[..<colon]).lowercased()
            guard name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 || (48...57).contains($0) }) else { throw RemoteHTTPError.malformed }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil && ["host", "content-length", "authorization", "origin", "transfer-encoding"].contains(name) { throw RemoteHTTPError.malformed }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { throw RemoteHTTPError.unsupportedEncoding }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(raw), parsed <= maximumBodySize else { throw RemoteHTTPError.tooLarge }
            length = parsed
        } else { length = 0 }
        let available = data.count - boundary.upperBound
        guard available >= length else { return nil }
        guard available == length else { throw RemoteHTTPError.malformed }
        return RemoteHTTPRequest(method: String(parts[0]), target: String(parts[1]), headers: headers, body: Data(data[boundary.upperBound...]))
    }

    nonisolated func isTrusted(hosts: Set<String>, port: Int, scheme: String = "http") -> Bool {
        guard scheme == "http" || scheme == "https" else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        guard let hostHeader = headers["host"], let hostURL = URLComponents(string: "\(scheme)://\(hostHeader)"),
              let host = hostURL.host?.lowercased(), hosts.contains(host),
              hostURL.user == nil, hostURL.password == nil, hostURL.path.isEmpty,
              hostURL.query == nil, hostURL.fragment == nil,
              (hostURL.port ?? defaultPort) == port else { return false }
        if let origin = headers["origin"] {
            guard let url = URLComponents(string: origin), url.scheme == scheme, url.host?.lowercased() == host,
                  (url.port ?? defaultPort) == port, url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil else { return false }
        }
        if headers["sec-fetch-site"] == "cross-site" && target != "/" { return false }
        return true
    }

    nonisolated var rawString: String? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        let header = headers.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        return "\(method) \(target) HTTP/1.1\r\n\(header)\r\n\r\n\(text)"
    }
}

/// All mutable reader state is confined to its queue.
nonisolated final class RemoteRequestReader: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "Torravia.HTTPReader")
    private var buffer = Data()
    private var finished = false
    private var timeout: DispatchWorkItem?
    private let completion: @Sendable (Result<RemoteHTTPRequest, Error>) -> Void

    nonisolated init(connection: NWConnection, completion: @escaping @Sendable (Result<RemoteHTTPRequest, Error>) -> Void) {
        self.connection = connection; self.completion = completion
    }
    nonisolated func start() {
        queue.async { [self] in
            connection.start(queue: queue)
            let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(RemoteHTTPError.timedOut)) }
            self.timeout = timeout
            queue.asyncAfter(deadline: .now() + 20, execute: timeout)
            receive()
        }
    }
    nonisolated private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            guard !finished else { return }
            if let error { finish(.failure(error)); return }
            if let data { buffer.append(data) }
            do {
                if let request = try RemoteHTTPRequest.parse(buffer) { finish(.success(request)); return }
                if complete { finish(.failure(RemoteHTTPError.malformed)); return }
                receive()
            } catch { finish(.failure(error)) }
        }
    }
    nonisolated private func finish(_ result: Result<RemoteHTTPRequest, Error>) {
        guard !finished else { return }
        finished = true; timeout?.cancel(); timeout = nil
        completion(result)
    }
}

nonisolated enum RemoteNetworkAddresses {
    nonisolated static func ipv4() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var addresses = Set<String>()
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.insert(String(cString: buffer))
            }
        }
        return addresses.sorted()
    }
}
