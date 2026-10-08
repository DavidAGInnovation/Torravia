@testable import TorraviaSearchCore
import Foundation
import Testing
@testable import Torravia

@MainActor
struct RSSRuleTests {
    @Test func parsesEpisodeFormatsAndValidDates() {
        for title in ["Harbor.S02E05.1080p", "Harbor 2x05 1080p", "Harbor.s2.e5", "Harbor.S02E05-1080p", "Harbor.2x05-720p"] {
            #expect(RSSEpisodeFilter.keys(in: title) == ["2x5"])
        }
        #expect(RSSEpisodeFilter.keys(in: "Harbor.S02E05E06") == ["2x5", "2x6"])
        #expect(RSSEpisodeFilter.keys(in: "Harbor.S02E05-E07") == ["2x5", "2x6", "2x7"])
        #expect(RSSEpisodeFilter.keys(in: "Harbor.2x05-07") == ["2x5", "2x6", "2x7"])
        #expect(RSSEpisodeFilter.keys(in: "Daily.2026.10.08") == ["2026-10-08"])
        #expect(RSSEpisodeFilter.keys(in: "Daily.08-10-2026") == ["2026-10-08"])
        #expect(RSSEpisodeFilter.keys(in: "Daily.2026.02.30").isEmpty)
        #expect(RSSEpisodeFilter.keys(in: "Harbor.S02.Complete.1080p").isEmpty)
        #expect(RSSEpisodeFilter.keys(in: "Anime 123 1080p").isEmpty)
    }

    @Test func selectsRangesWithoutPartiallyAcceptingEpisodeBundles() {
        #expect(RSSEpisodeFilter.matches("Harbor.S02E05", selection: "2x1-10;"))
        #expect(!RSSEpisodeFilter.matches("Harbor.S01E05", selection: "2x1-10;"))
        #expect(!RSSEpisodeFilter.matches("Harbor.S02E11", selection: "2x1-10;"))
        #expect(RSSEpisodeFilter.matches("Harbor.S03E01", selection: "2x5-;"))
        #expect(!RSSEpisodeFilter.matches("Harbor.S02E04", selection: "2x5-;"))
        #expect(RSSEpisodeFilter.matches("Harbor.S02E05", selection: "1x1;2x5;"))
        #expect(!RSSEpisodeFilter.matches("Harbor.S02E05E06", selection: "2x5;"))
        #expect(!RSSEpisodeFilter.matches("Harbor.S02", selection: "2x1-10;"))
        for value in ["garbage", "2x10-1;", ";", "2x;", "2x1 trailing"] {
            #expect(RSSEpisodeFilter.selections(value) == nil)
        }
    }

    @Test func smartHistoryAllowsOnlyNewEpisodesAndOptionalCorrections() {
        var rule = DownloadAutomationStore.RSSRule(feedURL: "https://example.com/rss", include: "Harbor", smartEpisodeFilter: true)
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(rule.matchReason(title: "Harbor.S02E05", now: now) == nil)
        rule.recordMatch(title: "Harbor.S02E05", now: now)
        #expect(rule.matchReason(title: "Harbor.2x5.OtherGroup", now: now) != nil)
        #expect(rule.matchReason(title: "Harbor.S02E06", now: now) == nil)
        #expect(rule.matchReason(title: "Harbor.S02E05.REPACK", now: now) != nil)
        rule.downloadRepacks = true
        #expect(rule.matchReason(title: "Harbor.S02E05.REPACK", now: now) == nil)
        rule.recordMatch(title: "Harbor.S02E05.REPACK.PROPER", now: now)
        #expect(rule.matchReason(title: "Harbor.S02E05.REPACK", now: now) != nil)
        #expect(rule.matchReason(title: "Harbor.S02E05.PROPER", now: now) != nil)
        #expect(rule.matchReason(title: "Harbor.S02.Complete", now: now) != nil)
        #expect(rule.matchReason(title: "Other.S02E06", now: now) != nil)
        var another = DownloadAutomationStore.RSSRule(feedURL: rule.feedURL, smartEpisodeFilter: true)
        #expect(another.matchReason(title: "Another.S02E05", now: now) == nil)
        another.recordMatch(title: "Daily.2026.10.08", now: now)
        #expect(another.matchReason(title: "Daily.08-10-2026", now: now) != nil)
    }

    @Test func cooldownStartsAfterAcceptedImportAndExpiresAtBoundary() {
        var rule = DownloadAutomationStore.RSSRule(feedURL: "https://example.com/rss", ignoreDays: 2)
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(rule.matchReason(title: "First", now: now) == nil)
        #expect(rule.lastMatch == nil) // Previewing never consumes a match.
        rule.recordMatch(title: "First", now: now)
        #expect(rule.matchReason(title: "Second", now: now.addingTimeInterval(172_799)) != nil)
        #expect(rule.matchReason(title: "Second", now: now.addingTimeInterval(172_800)) == nil)
    }

    @Test func migratesOldRulesAndPersistsNamedMultiFeedOrderingAndHistory() throws {
        let suite = "TorraviaTests.rssRules.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        defaults.set(try JSONSerialization.data(withJSONObject: [["id": id.uuidString, "feedURL": "https://example.com/a", "include": "Linux"]]), forKey: "automation.rssRules")
        defaults.set(["https://example.com/a"], forKey: "automation.rssFeeds")
        let store = DownloadAutomationStore(userDefaults: defaults)
        #expect(store.rssRules.count == 1)
        #expect(store.rssRules[0].id == id)
        #expect(!store.rssRules[0].smartEpisodeFilter)
        let harbor = try #require(store.addRSSRule(feedURL: "https://example.com/a", include: "Harbor",
            name: "Harbor", additionalFeedURLs: ["https://example.com/b", "https://example.com/a"],
            smartEpisodeFilter: true, ignoreDays: 1))
        let other = try #require(store.addRSSRule(feedURL: "https://example.com/a", include: "Other", name: "Other", smartEpisodeFilter: true))
        #expect(store.rssRules.count == 3)
        #expect(store.rssFeedURLs == ["https://example.com/a", "https://example.com/b"])
        let now = Date(timeIntervalSince1970: 100_000)
        var staleEditor = try #require(store.rssRules.first { $0.id == harbor })
        store.recordRSSMatch(id: harbor, title: "Harbor.S02E05", now: now)
        staleEditor.name = "Renamed"
        #expect(store.updateRSSRule(staleEditor))
        #expect(store.matchingRule(feedURL: "https://example.com/b", title: "Harbor.S02E05", now: now.addingTimeInterval(86400)) == nil)
        #expect(store.matchingRule(feedURL: "https://example.com/a", title: "Other.S02E05", now: now)?.id == other)
        store.moveRSSRule(id: harbor, offset: -1)
        let restored = DownloadAutomationStore(userDefaults: defaults)
        #expect(restored.rssRules.first?.id == harbor)
        #expect(restored.rssRules.first?.name == "Renamed")
        #expect(restored.rssRules.first?.previouslyMatchedEpisodes == ["2x5"])
        #expect(restored.rssRules.first?.lastMatch == now)
        restored.resetRSSHistory(id: harbor)
        #expect(restored.matchingRule(feedURL: "https://example.com/b", title: "Harbor.S02E05", now: now)?.id == harbor)
        restored.removeRSSRule(id: other)
        #expect(restored.rssRules.count == 2)
        #expect(restored.rssFeedURLs.count == 2)
        restored.removeRSSFeed(at: IndexSet(integer: 0))
        #expect(restored.rssRules.count == 1)
        #expect(restored.rssRules.first?.feedURL == "https://example.com/b")
    }

    @Test func firstEligibleRuleWinsAndCapAppliesAcrossFeeds() throws {
        let suite = "TorraviaTests.rssOrder.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DownloadAutomationStore(userDefaults: defaults)
        let first = try #require(store.addRSSRule(feedURL: "https://example.com/a", maxItemsPerPoll: 1, additionalFeedURLs: ["https://example.com/b"]))
        let second = try #require(store.addRSSRule(feedURL: "https://example.com/a"))
        #expect(store.matchingRule(feedURL: "https://example.com/a", title: "Harbor")?.id == first)
        #expect(store.matchingRule(feedURL: "https://example.com/a", title: "Harbor", counts: [first: 1])?.id == second)
        #expect(store.matchingRule(feedURL: "https://example.com/b", title: "Harbor", counts: [first: 1]) == nil)
        store.moveRSSRule(id: second, offset: -1)
        #expect(store.matchingRule(feedURL: "https://example.com/a", title: "Harbor")?.id == second)
    }
}
