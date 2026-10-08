@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

@MainActor struct TrackerRankedSearchTests {
    @Test func activeMatchesSurviveStaleIndexedCountsAndTheDisplayLimit() async throws {
        let staleHash = String(repeating: "a", count: 40)
        let activeHash = String(repeating: "b", count: 40)
        let stale = TorrentItem(title: "Naruto stale", seeders: 999_999, leechers: 9000, sizeBytes: 100,
            magnetLink: "magnet:?xt=urn:btih:" + staleHash, source: "Stale index")
        let active = TorrentItem(title: "Naruto active", seeders: 1, leechers: 0, sizeBytes: 200,
            magnetLink: "magnet:?xt=urn:btih:" + activeHash, source: "Active index")
        let fast = ControlledSearchProvider(), slow = ControlledSearchProvider()
        var updates: [[TorrentItem]] = []
        let task = Task { @MainActor in
            try await SearchProvider(providers: [("fast", fast), ("slow", slow)], maxResults: 1)
                .search(query: "Naruto", finishWhenFull: false, limitResults: false) { items in
                    updates.append(items)
                    if updates.count == 1 { slow.complete(with: [active]) }
                }
        }
        await fast.waitUntilStarted(); await slow.waitUntilStarted()
        defer { fast.complete(with: []); slow.complete(with: []) }
        fast.complete(with: [stale])
        let candidates = try await task.value
        #expect(updates.first == [stale])
        #expect(updates.last == candidates && candidates.count == 2)
        let counts = SearchPeerCountsStore(lookup: { magnet in
            TrackerPeerEstimate(seeders: TrackerPeerScraper.infoHash(in: magnet) == activeHash ? 27 : 0,
                leechers: 0, checkedAt: Date(), tracker: URL(string: "udp://tracker.example:80/announce")!)
        })
        await counts.checkAll(candidates, allowed: true)
        #expect(SearchResultsSortOrder.seeders.sorted(candidates, peerStates: counts.states, limit: 1) == [active])
        #expect(counts.state(for: stale).seeders == 0)
        #expect(counts.state(for: active).seeders == 27)
        // The retained pool also supports changing sort without another search.
        #expect(SearchResultsSortOrder.sizeAscending.sorted(candidates, peerStates: counts.states, limit: 1) == [stale])
        #expect(SearchResultsSortOrder.sizeDescending.sorted(candidates, peerStates: counts.states, limit: 1) == [active])
    }

    @Test func checkedZeroRemainsHonestWhenNoPositiveEstimateExists() {
        let zero = TorrentItem(title: "Naruto zero", seeders: 99999, leechers: 0, sizeBytes: 10,
            magnetLink: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40))
        let unknown = TorrentItem(title: "Naruto unknown", seeders: 999999, leechers: 0, sizeBytes: 20,
            magnetLink: "magnet:?xt=urn:btih:" + String(repeating: "b", count: 40))
        let states = [String(repeating: "a", count: 40): SearchPeerCountState(estimate: TrackerPeerEstimate(
            seeders: 0, leechers: 0, checkedAt: Date(), tracker: URL(string: "udp://tracker.example:80/announce")!))]
        #expect(SearchResultsSortOrder.seeders.sorted([unknown, zero], peerStates: states, limit: 1) == [zero])
        #expect(states[String(repeating: "a", count: 40)]?.seedersLabel(for: zero) == "0 tracker seeders")
    }
}
