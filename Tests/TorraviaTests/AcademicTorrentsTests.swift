import Foundation
import Testing
@testable import Torravia
@testable import TorraviaSearchCore

private final class AcademicFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let feed = url.path == "/database.xml"
        let body = feed ? """
        <rss><channel>
        <item><title>Ocean research &amp; observations</title><infohash>0123456789abcdef0123456789abcdef01234567</infohash><size>4096</size><link>https://academictorrents.com/details/fixture</link></item>
        <item><title>Unrelated dataset</title><infohash>1111111111111111111111111111111111111111</infohash><size>8</size></item>
        <item><title>Ocean research invalid hash</title><infohash>invalid</infohash><size>4</size></item>
        </channel></rss>
        """ : "Details temporarily unavailable"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: feed ? 200 : 503, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor struct AcademicTorrentsTests {
    @Test func matchingDatasetSurvivesUnavailableDetailsAndRejectsInvalidHashes() async throws {
        let configuration = SearchProvider.sessionConfiguration(mode: .balanced)
        configuration.protocolClasses = [AcademicFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let results = try await AcademicTorrentsSearchProvider(session: session, trackers: []).search(query: "ocean research")
        #expect(results.count == 1)
        let item = try #require(results.first)
        #expect(item.title == "Ocean research & observations")
        #expect(item.sizeBytes == 4096)
        #expect(item.source == "Academic Torrents")
        #expect(TorrentMetadata.canonicalMagnetIdentity(item.magnetLink) == "btih:0123456789abcdef0123456789abcdef01234567")
        #expect(MagnetLink.components(item.magnetLink)?.queryItems?.contains { $0.name == "tr" } == false)
    }

    #if !TORRAVIA_PRIVATE
    @Test func publicCatalogAndStoredPreferencesContainOnlyAcademicTorrents() throws {
        #expect(TorrentSearchSite.allCases == [.academicTorrents])
        #expect(TorrentSearchSite.defaultEnabled == [.academicTorrents])
        let suite = "TorraviaTests.PublicPreferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["unavailableProvider"], forKey: "public.search.preferences.enabledSites")
        defaults.set(["existingPrivateSelection"], forKey: "search.preferences.enabledSites")
        let store = SearchPreferencesStore(userDefaults: defaults)
        #expect(store.enabledSites == [.academicTorrents])
        #expect(defaults.stringArray(forKey: "search.preferences.enabledSites") == ["existingPrivateSelection"])
        #expect(TorrentSearchSite.stateDirectoryName == "TorraviaPublic")
    }
    #endif
}
