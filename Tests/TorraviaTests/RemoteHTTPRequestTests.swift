@testable import TorraviaSearchCore
import Foundation
import Testing
@testable import Torravia

@MainActor
struct RemoteHTTPRequestTests {
    @Test func waitsForFragmentedHeadersAndFullBody() throws {
        let header = "POST /api/preferences HTTP/1.1\r\nHost: localhost:8555\r\nContent-Length: 4\r\n\r\n"
        #expect(try RemoteHTTPRequest.parse(Data("POST /api/preferences HTTP/1.1\r\nHost:".utf8)) == nil)
        #expect(try RemoteHTTPRequest.parse(Data((header + "te").utf8)) == nil)
        let request = try #require(try RemoteHTTPRequest.parse(Data((header + "test").utf8)))
        #expect(request.body == Data("test".utf8))
        #expect(request.isTrusted(hosts: ["localhost"], port: 8555))
    }

    @Test func rejectsRequestSmugglingAndOversizedBodies() {
        for raw in [
            "POST / HTTP/1.1\r\nHost: localhost:8555\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\na",
            "POST / HTTP/1.1\r\nHost: localhost:8555\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost:8555\r\nContent-Length: 8388609\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: localhost:8555\r\n\r\nGET /api HTTP/1.1\r\n\r\n",
            "GET //evil.example/api HTTP/1.1\r\nHost: localhost:8555\r\n\r\n"
        ] { #expect(throws: RemoteHTTPError.self) { try RemoteHTTPRequest.parse(Data(raw.utf8)) } }
    }

    @Test func rejectsForeignHostAndOriginWhileAcceptingLocalDevices() throws {
        func request(host: String, extra: String = "") throws -> RemoteHTTPRequest {
            try #require(try RemoteHTTPRequest.parse(Data("GET /api/downloads HTTP/1.1\r\nHost: \(host)\r\n\(extra)\r\n".utf8)))
        }
        let hosts: Set<String> = ["127.0.0.1", "localhost", "192.168.1.2"]
        #expect(try request(host: "192.168.1.2:8555", extra: "Origin: http://192.168.1.2:8555\r\n").isTrusted(hosts: hosts, port: 8555))
        #expect(try !request(host: "evil.example:8555").isTrusted(hosts: hosts, port: 8555))
        #expect(try !request(host: "localhost:8555", extra: "Origin: https://evil.example\r\n").isTrusted(hosts: hosts, port: 8555))
        #expect(try !request(host: "localhost:8555", extra: "Sec-Fetch-Site: cross-site\r\n").isTrusted(hosts: hosts, port: 8555))
        #expect(try !request(host: "localhost:8556").isTrusted(hosts: hosts, port: 8555))
        #expect(try !request(host: "evil@localhost:8555").isTrusted(hosts: hosts, port: 8555))
    }

    @Test func httpsOriginMustMatchTransportHostAndPort() throws {
        func request(_ host: String, origin: String) throws -> RemoteHTTPRequest {
            try #require(try RemoteHTTPRequest.parse(Data("GET /api/downloads HTTP/1.1\r\nHost: \(host)\r\nOrigin: \(origin)\r\n\r\n".utf8)))
        }
        let hosts: Set<String> = ["localhost", "torrents.example.com"]
        #expect(try request("localhost:8555", origin: "https://localhost:8555").isTrusted(hosts: hosts, port: 8555, scheme: "https"))
        #expect(try !request("localhost:8555", origin: "http://localhost:8555").isTrusted(hosts: hosts, port: 8555, scheme: "https"))
        #expect(try !request("localhost:8555", origin: "https://localhost:8556").isTrusted(hosts: hosts, port: 8555, scheme: "https"))
        #expect(try !request("localhost:8555", origin: "https://user:password@localhost:8555").isTrusted(hosts: hosts, port: 8555, scheme: "https"))
        #expect(try request("torrents.example.com", origin: "https://torrents.example.com").isTrusted(hosts: hosts, port: 443, scheme: "https"))
        #expect(try !request("torrents.example.com", origin: "https://torrents.example.com").isTrusted(hosts: hosts, port: 80, scheme: "https"))
    }

    @Test func certificateHostnameAcceptsDNSNamesOnly() throws {
        #expect(try RemoteTLSConfiguration.hostname(" Torrents.Example.com ") == "torrents.example.com")
        #expect(try RemoteTLSConfiguration.hostname(" ") == nil)
        for value in ["https://example.com", "example.com:8555", "example.com/path", "user@example.com", "-bad.example", "bad..example", "bad_.example"] {
            #expect(throws: RemoteTLSError.self) { try RemoteTLSConfiguration.hostname(value) }
        }
    }
}
