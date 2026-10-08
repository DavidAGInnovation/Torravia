@testable import TorraviaSearchCore
import Foundation
import Network
import Security
import Testing
@testable import Torravia

/// Trust only the fixture CA, retaining hostname and server-auth checks at the fixture date.
nonisolated private final class FixtureTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let root = SecCertificateCreateWithData(nil, RemoteHTTPSFixture.rootCertificate as CFData),
              SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetVerifyDate(trust, RemoteHTTPSFixture.verificationDate as CFDate) == errSecSuccess else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            Issue.record("Fixture certificate trust failed: \(String(describing: error))")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@MainActor
struct RemoteHTTPSIntegrationTests {
    @Test func certificatePersistsAndLiveHTTPSPreservesAccessControls() async throws {
        #expect(throws: RemoteTLSError.self) {
            try RemoteTLSIdentity.importPKCS12(RemoteHTTPSFixture.pkcs12, password: "wrong-password")
        }
        let identity = try RemoteTLSIdentity.importPKCS12(RemoteHTTPSFixture.pkcs12, password: RemoteHTTPSFixture.password)
        defer {
            SecItemDelete([kSecClass as String: kSecClassIdentity,
                           kSecValuePersistentRef as String: identity.persistentReference] as CFDictionary)
        }
        #expect(identity.name == "TorrentScout TEST ONLY")
        #expect(identity.certificateChain.count >= 2)
        _ = try identity.protocolIdentity()

        let suite = "TorraviaTests.https.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let initial = SeedingPreferencesStore(userDefaults: defaults)
        initial.remoteControlTLSIdentity = identity
        initial.remoteControlUsesHTTPS = true
        initial.remoteControlPort = Int.random(in: 20_000...60_000)
        initial.isRemoteControlEnabled = true
        // Reconstruct preferences to prove that no password or .p12 file is needed after import.
        let preferences = SeedingPreferencesStore(userDefaults: defaults)
        #expect(preferences.remoteControlTLSIdentity == identity)
        #expect(preferences.remoteControlUsesHTTPS)
        let model = DownloadsViewModel(session: WebTorrentSession(), preferences: preferences,
                                      downloadLocation: DownloadLocationStore(userDefaults: defaults),
                                      automation: DownloadAutomationStore(userDefaults: defaults),
                                      persistenceURL: directory.appendingPathComponent("downloads.json"), startServices: false)
        defer { model.remoteListener?.cancel(); model.remoteConnections.values.forEach { $0.cancel() } }
        func ready() async throws -> URL {
            for _ in 0..<100 {
                if model.remoteControlURL != nil || model.remoteControlError != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(model.remoteControlError == nil)
            return try #require(model.remoteControlURL)
        }
        model.configureRemoteControl()
        let root = try await ready()
        #expect(root.scheme == "https")
        let client = URLSession(configuration: .ephemeral, delegate: FixtureTrustDelegate(), delegateQueue: nil)
        defer { client.invalidateAndCancel() }
        func request(_ path: String, authenticated: Bool = true, origin: String? = nil,
                     method: String = "GET", body: [String: Any]? = nil, host: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: root.appendingPathComponent(path))
            request.timeoutInterval = 5
            request.httpMethod = method
            if authenticated { request.setValue("Bearer \(model.remoteControlToken)", forHTTPHeaderField: "Authorization") }
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            if let host { request.setValue(host, forHTTPHeaderField: "Host") }
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await client.data(for: request)
            return (data, try #require(response as? HTTPURLResponse))
        }
        let (_, landing) = try await request("", authenticated: false)
        #expect(landing.statusCode == 200)
        #expect(landing.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("frame-ancestors 'none'") == true)
        for asset in ["web.js", "web.css", "web-icons.svg"] {
            let (_, response) = try await request(asset, authenticated: false)
            #expect(response.statusCode == 200)
        }
        let (_, unauthenticated) = try await request("api/preferences", authenticated: false)
        #expect(unauthenticated.statusCode == 401)
        let origin = "https://127.0.0.1:\(preferences.remoteControlPort)"
        let (capabilities, allowed) = try await request("api/capabilities", origin: origin)
        #expect(allowed.statusCode == 200)
        #expect(String(decoding: capabilities, as: UTF8.self).contains("HTTPS with token authentication"))
        let (_, wrongScheme) = try await request("api/preferences", origin: origin.replacingOccurrences(of: "https:", with: "http:"))
        #expect(wrongScheme.statusCode == 403)
        let (_, foreignOrigin) = try await request("api/preferences", origin: "https://evil.example")
        #expect(foreignOrigin.statusCode == 403)
        let (_, foreignHost) = try await request("api/preferences", host: "evil.example:\(preferences.remoteControlPort)")
        #expect(foreignHost.statusCode == 403)
        let (_, saved) = try await request("api/preferences", origin: origin, method: "PUT", body: ["downloadLimitMBps": 7])
        #expect(saved.statusCode == 200)
        #expect(preferences.downloadLimitMBps == 7)

        let port = try #require(NWEndpoint.Port(rawValue: UInt16(preferences.remoteControlPort)))
        #expect(await RemoteHTTPSProbe(port: port, version: .TLSv12).run() == .connected)
        #expect(await RemoteHTTPSProbe(port: port, version: .TLSv11).run() == .rejected)

        var insecureURL = try #require(URLComponents(url: root, resolvingAgainstBaseURL: false))
        insecureURL.scheme = "http"
        var insecureRequest = URLRequest(url: try #require(insecureURL.url))
        insecureRequest.timeoutInterval = 3
        do {
            _ = try await client.data(for: insecureRequest)
            Issue.record("The HTTPS listener accepted a plain HTTP request")
        } catch { /* TLS must reject the plaintext request. */ }

        // Certificate replacement and removal stop existing listeners, without HTTP fallback.
        let oldListener = try #require(model.remoteListener)
        preferences.remoteControlTLSIdentity = nil
        model.configureRemoteControl()
        for _ in 0..<100 {
            if model.remoteControlError != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.remoteListener == nil)
        #expect(model.remoteControlURL == nil)
        #expect(model.remoteControlError?.contains("Import an HTTPS certificate") == true)
        preferences.remoteControlTLSIdentity = identity
        model.configureRemoteControl()
        #expect(try await ready().scheme == "https")
        #expect(model.remoteListener !== oldListener)
        preferences.remoteControlUsesHTTPS = false
        model.configureRemoteControl()
        #expect(try await ready().scheme == "http")
    }

    @Test func missingAndUnreadableCertificatesFailClosed() {
        #expect(throws: RemoteTLSError.self) { try RemoteTLSConfiguration.parameters(useHTTPS: true, identity: nil) }
        let invalid = RemoteTLSIdentity(persistentReference: Data([0]), certificateChain: [], name: "Missing")
        #expect(throws: RemoteTLSError.self) { try RemoteTLSConfiguration.parameters(useHTTPS: true, identity: invalid) }
        #expect(throws: Never.self) { try RemoteTLSConfiguration.parameters(useHTTPS: false, identity: nil) }
    }
}
