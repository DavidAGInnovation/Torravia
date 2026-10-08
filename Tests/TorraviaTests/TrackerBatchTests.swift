@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

@MainActor
struct TrackerBatchTests {
    @Test func trackerBatchWaitsForAllResultsLimitsConcurrencyAndCachesZero() async {
        let lookup = ControlledPeerLookup()
        let store = SearchPeerCountsStore(concurrency: 1, lookup: { await lookup.lookup($0) })
        let item = TorrentItem(title: "Ubuntu", seeders: 9000, leechers: 40, sizeBytes: 1,
            magnetLink: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40))
        let second = TorrentItem(title: "Second", seeders: 5000, leechers: 0, sizeBytes: 1,
            magnetLink: "magnet:?xt=urn:btih:" + String(repeating: "b", count: 40))
        let invalid = TorrentItem(title: "Invalid", seeders: 10000, leechers: 0, sizeBytes: 1, magnetLink: "")
        var published = false
        let batch = Task { @MainActor in
            await store.checkAll([item, item, second, invalid], allowed: true)
            published = true
        }
        await lookup.waitForCalls(1)
        #expect(!published)
        #expect(await lookup.calls == 1)
        #expect(store.state(for: item).seedersLabel(for: item) == "Unknown tracker seeders")
        let estimate = TrackerPeerEstimate(seeders: 0, leechers: 0, checkedAt: Date(), tracker: URL(string: "udp://tracker.example:80/announce")!)
        await lookup.completeAll(estimate)
        await lookup.waitForCalls(2)
        #expect(!published)
        #expect(store.state(for: item).estimate == estimate)
        await lookup.completeAll(nil)
        await batch.value
        #expect(published)
        #expect(store.state(for: second).checkedAt != nil)
        #expect(store.state(for: invalid).seeders == nil)
        await store.checkAll([item, second], allowed: true)
        #expect(await lookup.calls == 2)
        #expect(item.seeders == 9000)
        await store.checkAll([item], allowed: false)
        #expect(store.states.isEmpty)
        #expect(store.state(for: item).seeders == nil)
        #expect(await lookup.calls == 2)
    }

    @Test func cancelledPeerChecksCannotUpdateANewerSearch() async {
        let lookup = ControlledPeerLookup()
        let store = SearchPeerCountsStore(concurrency: 1, lookup: { await lookup.lookup($0) })
        let first = TorrentItem(title: "Old", seeders: 1, leechers: 2, sizeBytes: 1,
            magnetLink: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40))
        let next = TorrentItem(title: "New", seeders: 3, leechers: 4, sizeBytes: 1,
            magnetLink: "magnet:?xt=urn:btih:" + String(repeating: "b", count: 40))
        let oldBatch = Task { await store.checkAll([first, next], allowed: true) }
        await lookup.waitForCalls(1)
        #expect(await lookup.calls == 1)
        store.cancel()
        await lookup.completeAll(TrackerPeerEstimate(seeders: 100, leechers: 50, checkedAt: Date(), tracker: URL(string: "udp://tracker.example:80/announce")!))
        await oldBatch.value
        #expect(store.states.isEmpty)
        #expect(await lookup.calls == 1)
        let nextBatch = Task { await store.checkAll([next], allowed: true) }
        await lookup.waitForCalls(2)
        await lookup.completeAll(nil)
        await nextBatch.value
        #expect(store.state(for: next).unavailableReason == .noResponse)
        await store.checkAll([next], allowed: true)
        #expect(await lookup.calls == 2)
        store.cancel()
    }

    @Test func cancellingSearchTaskCancelsItsTrackerBatch() async {
        let lookup = ControlledPeerLookup()
        let store = SearchPeerCountsStore(concurrency: 1, lookup: { await lookup.lookup($0) })
        let item = TorrentItem(title: "Cancelled", seeders: 9000, leechers: 0, sizeBytes: 1,
            magnetLink: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40))
        let batch = Task { await store.checkAll([item], allowed: true) }
        await lookup.waitForCalls(1)
        batch.cancel()
        await lookup.completeAll(TrackerPeerEstimate(seeders: 100, leechers: 0,
            checkedAt: Date(), tracker: URL(string: "udp://tracker.example:80/announce")!))
        await batch.value
        #expect(store.states.isEmpty)
    }

    @Test func duplicateResultsPreserveTrackersFromBothSourcesAndRetryFailedChecks() async {
        let hash = String(repeating: "a", count: 40)
        let privateTracker = "udp://private.example:80/announce"
        let publicTracker = "udp://tracker.opentrackr.org:1337/announce"
        let original = TorrentItem(title: "Sintel", seeders: 1, leechers: 0, sizeBytes: 1,
            magnetLink: "magnet:?xt=urn:btih:\(hash)&dn=[First]%5BTitle%5D&tr=\(privateTracker)", source: "First")
        let candidate = original.replacingMagnetLink(with: "magnet:?xt=urn:btih:\(hash)&tr=\(publicTracker)&tr=\(publicTracker)")
        let merged = original.merging(candidate)
        let trackers = MagnetLink.components(merged.magnetLink)?.queryItems?.filter { $0.name == "tr" }.compactMap(\.value)
        #expect(trackers == [privateTracker, publicTracker])
        #expect(MagnetLink.components(merged.magnetLink)?.queryItems?.first { $0.name == "dn" }?.value == "[First][Title]")
        let otherHash = candidate.replacingMagnetLink(with: "magnet:?xt=urn:btih:" + String(repeating: "b", count: 40) + "&tr=\(publicTracker)")
        #expect(original.merging(otherHash).magnetLink == original.magnetLink)
        let lookup = ControlledPeerLookup()
        let store = SearchPeerCountsStore(lookup: { await lookup.lookup($0) }, approvedTrackers: [publicTracker])
        let first = Task { await store.checkAll([original], allowed: true) }
        await lookup.waitForCalls(1)
        await lookup.completeAll(nil)
        await first.value
        let retry = Task { await store.checkAll([merged], allowed: true) }
        await lookup.waitForCalls(2)
        await lookup.completeAll(TrackerPeerEstimate(seeders: 6, leechers: 0, checkedAt: Date(), tracker: URL(string: publicTracker)!))
        await retry.value
        #expect(store.state(for: merged).seeders == 6)
    }

    @Test func unavailableCountsExplainPrivacyUnsupportedMagnetsAndUnapprovedTrackers() async {
        let item = TorrentItem(title: "Private", seeders: 50, leechers: 5, sizeBytes: 1,
            magnetLink: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40) + "&tr=udp://private.example:80/announce")
        let store = SearchPeerCountsStore()
        await store.checkAll([item], allowed: true)
        #expect(store.state(for: item).unavailableReason == .noApprovedTrackers)
        #expect(store.state(for: item).seeders == nil)
        #expect(store.state(for: item).detail == "No supported public tracker in this magnet")
        await store.checkAll([item], allowed: false)
        #expect(store.state(for: item).unavailableReason == .networkPolicy)
        #expect(store.state(for: item).seeders == nil)
        let v2 = item.replacingMagnetLink(with: "magnet:?xt=urn:btmh:1220" + String(repeating: "a", count: 64))
        await store.checkAll([v2], allowed: true)
        #expect(store.state(for: v2).unavailableReason == .unsupportedMagnet)
        #expect(store.state(for: v2).seeders == nil)
    }
}
