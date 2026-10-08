@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

@MainActor
struct DownloadAutomationTests {
    @MainActor
    @Test func automationStorePersistsRSSFeeds() throws {
        let suiteName = "TorraviaTests.automation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DownloadAutomationStore(userDefaults: defaults)
        store.addRSSRule(feedURL: "https://example.com/feed.xml",
                         include: "linux, x86",
                         exclude: "beta",
                         category: "Linux",
                         matchAll: true,
                         maxItemsPerPoll: 7,
                         tags: ["desktop", "linux"],
                         startPaused: true,
                         sequential: true,
                         queuePriority: 1)
        store.addRSSFeed("not-a-url")
        #expect(store.rssFeedURLs == ["https://example.com/feed.xml"])
        #expect(store.rssRules.first?.include == "linux, x86")
        #expect(store.rssRules.first?.exclude == "beta")
        #expect(store.rssRules.first?.category == "Linux")
        #expect(store.rssRules.first?.matchAll == true)
        #expect(store.rssRules.first?.maxItemsPerPoll == 7)
        #expect(store.rssRules.first?.tags == ["desktop", "linux"])
        #expect(store.rssRules.first?.startPaused == true)
        #expect(store.rssRules.first?.sequential == true)
        #expect(store.rssRules.first?.queuePriority == 1)

        let restored = DownloadAutomationStore(userDefaults: defaults)
        #expect(restored.rssFeedURLs == ["https://example.com/feed.xml"])
        #expect(restored.rssRules.first?.category == "Linux")
        #expect(restored.rssRules.first?.tags == ["desktop", "linux"])
        #expect(restored.rssRules.first?.queuePriority == 1)
    }

    @Test func rssRulesSupportRegexAndSafeLiteralFallback() {
        #expect(DownloadsViewModel.rssRuleMatches(title: "Ubuntu 25.04 Desktop",
                                                  include: "Ubuntu\\s+25\\.04",
                                                  exclude: "beta|rc"))
        #expect(!DownloadsViewModel.rssRuleMatches(title: "Ubuntu 25.04 beta",
                                                   include: "Ubuntu\\s+25\\.04",
                                                   exclude: "beta|rc"))
        #expect(DownloadsViewModel.rssRuleMatches(title: "Linux x86_64",
                                                  include: "linux, x86",
                                                  exclude: "[invalid"))
        #expect(DownloadsViewModel.rssRuleMatches(title: "Linux x86_64",
                                                  include: "linux, x86",
                                                  exclude: "",
                                                  matchAll: true))
        #expect(!DownloadsViewModel.rssRuleMatches(title: "Linux arm64",
                                                   include: "linux, x86",
                                                   exclude: "",
                                                   matchAll: true))
    }
}
