@testable import TorraviaSearchCore
import Foundation
import Testing
@testable import Torravia

private final class RSSFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    static func count(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[path, default: 0]
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "rss-fixture.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); Self.counts[url.path, default: 0] += 1; Self.lock.unlock()
        let cached = request.value(forHTTPHeaderField: "If-None-Match") != nil
        let status = url.path == "/feed" && cached ? 304 : 200
        let text = url.path == "/feed" ? """
        <rss><channel><item><title>Harbor.S02E05.1080p</title><guid>episode-five</guid>
        <enclosure url="https://rss-fixture.example/broken.torrent"/></item></channel></rss>
        """ : "not a torrent"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["ETag": "rss-v1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: status == 304 ? Data() : Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
struct RSSPollingTests {
    @Test func failedEnclosuresRemainEligibleOnUnchangedFeeds() async throws {
        let suite = "TorraviaTests.rssPolling.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = DownloadAutomationStore(userDefaults: defaults)
        let id = try #require(store.addRSSRule(feedURL: "https://rss-fixture.example/feed", smartEpisodeFilter: true))
        let model = DownloadsViewModel(session: WebTorrentSession(), preferences: SeedingPreferencesStore(userDefaults: defaults),
            downloadLocation: DownloadLocationStore(userDefaults: defaults), automation: store,
            persistenceURL: directory.appendingPathComponent("downloads.json"), startServices: false)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RSSFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let attemptsBefore = RSSFixtureProtocol.count("/broken.torrent")
        await model.pollRSSFeeds(session: session)
        #expect(model.rssCachedFeedData["https://rss-fixture.example/feed"] != nil)
        #expect(model.rssFeedStates["https://rss-fixture.example/feed"]?.itemCount == 1)
        #expect(model.downloads.isEmpty)
        #expect(store.rssRules.first?.previouslyMatchedEpisodes.isEmpty == true)
        #expect(store.rssRules.first?.lastMatch == nil)
        // A 304 must reprocess cached articles, rather than silently losing retries or edited rules.
        await model.pollRSSFeeds(session: session)
        #expect(model.rssFeedStates["https://rss-fixture.example/feed"]?.importedCount == 0)
        #expect(model.rssFeedStates["https://rss-fixture.example/feed"]?.lastError == nil)
        #expect(store.matchingRule(feedURL: "https://rss-fixture.example/feed", title: "Harbor.S02E05")?.id == id)
        #expect(RSSFixtureProtocol.count("/broken.torrent") == attemptsBefore + 2)
        #expect(!model.rssPollInProgress)
    }
}
