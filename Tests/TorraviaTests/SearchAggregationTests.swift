@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

@MainActor
struct SearchAggregationTests {
    @Test func mergingPreservesRealTitleOverMagnetPlaceholder() {
        let real = TorrentItem(
            title: "TeraLeak 13102024",
            seeders: 13,
            leechers: 1,
            sizeBytes: 100,
            magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            source: "Bitsearch"
        )
        let placeholder = TorrentItem(
            title: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            seeders: 0,
            leechers: 0,
            sizeBytes: 0,
            magnetLink: real.magnetLink,
            source: "BTDig"
        )

        #expect(real.merging(placeholder).title == real.title)
        #expect(placeholder.merging(real).title == real.title)
    }

    @Test func aggregationDropsUnrelatedProviderRowsBeforeApplyingResultCap() async throws {
        let stale = TorrentItem(
            title: "Latest unrelated release",
            seeders: 999,
            leechers: 0,
            sizeBytes: 1,
            magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        )
        let matching = TorrentItem(
            title: "Ubuntu 24.04 desktop",
            seeders: 1,
            leechers: 0,
            sizeBytes: 2,
            magnetLink: "magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789abcdef01"
        )

        let results = try await SearchProvider(
            providers: [("stub", StaticSearchProvider(items: [stale, matching]))],
            maxResults: 1
        ).search(query: "ubuntu")

        #expect(results.count == 1)
        #expect(results.first?.title == matching.title)
    }

    @Test func searchShowsMatchesBeforeSlowProvidersAndMergesDuplicates() async throws {
        let fast = ControlledSearchProvider()
        let slow = ControlledSearchProvider()
        let matching = TorrentItem(title: "Ubuntu desktop", seeders: 2, leechers: 0, sizeBytes: 2,
                                   magnetLink: "magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789abcdef01", source: "Fast")
        let duplicate = TorrentItem(title: matching.title, seeders: 8, leechers: 1, sizeBytes: 2,
                                    magnetLink: matching.magnetLink + "&dn=Ubuntu", source: "Slow")
        let unrelated = TorrentItem(title: "Unrelated release", seeders: 999, leechers: 0, sizeBytes: 1,
                                    magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        var updates: [[TorrentItem]] = []
        let task = Task { @MainActor in
            try await SearchProvider(providers: [("fast", fast), ("slow", slow)], maxResults: 1)
                .search(query: "ubuntu", finishWhenFull: false) { items in
                    updates.append(items)
                    // The slow site only completes after the first usable
                    // results have reached the UI callback.
                    if updates.count == 1 { slow.complete(with: [duplicate]) }
                }
        }
        await fast.waitUntilStarted()
        await slow.waitUntilStarted()
        defer { fast.complete(with: []); slow.complete(with: []) }
        fast.complete(with: [unrelated, matching])
        let results = try await task.value
        #expect(updates.first == [matching])
        #expect(results.count == 1)
        #expect(results.first?.seeders == 8)
        #expect(results.first?.id == matching.id)
        #expect(results.first?.source == "Fast, Slow")
        #expect(updates.last == results)
    }

    @Test func filledSearchDoesNotWaitForAnUnresponsiveProvider() async throws {
        let fast = ControlledSearchProvider()
        let slow = ControlledSearchProvider()
        let matching = TorrentItem(title: "Ubuntu desktop", seeders: 2, leechers: 0, sizeBytes: 2,
                                   magnetLink: "magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789abcdef01")
        let task = Task { @MainActor in
            try await SearchProvider(providers: [("fast", fast), ("slow", slow)], maxResults: 1)
                .search(query: "ubuntu")
        }
        await fast.waitUntilStarted()
        await slow.waitUntilStarted()
        defer { fast.complete(with: []); slow.complete(with: []) }
        let start = ContinuousClock.now
        fast.complete(with: [matching])
        let results = try await task.value
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(results == [matching])
    }

    @Test func cancelledSearchReturnsPromptlyWithoutPublishingResults() async throws {
        let slow = ControlledSearchProvider()
        var updates = 0
        let task = Task { @MainActor in
            try await SearchProvider(providers: [("slow", slow)])
                .search(query: "ubuntu") { _ in updates += 1 }
        }
        await slow.waitUntilStarted()
        defer { slow.complete(with: []) }
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled search must throw CancellationError")
        } catch is CancellationError {
            #expect(start.duration(to: .now) < .seconds(1))
        }
        #expect(updates == 0)
    }
}
