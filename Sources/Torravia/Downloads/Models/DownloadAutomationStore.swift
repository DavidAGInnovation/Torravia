//
//  DownloadAutomationStore.swift
//  Torravia
//
//  Watched-folder and RSS automation state, kept separate from the torrent
//  engine and the download presentation model.
//

import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

@MainActor
final class DownloadAutomationStore: ObservableObject {
    static let shared = DownloadAutomationStore()

    struct RSSRule: Identifiable, Codable, Equatable {
        let id: UUID
        var feedURL: String
        var name: String
        var additionalFeedURLs: [String]
        var episodeFilter: String
        var smartEpisodeFilter: Bool
        var downloadRepacks: Bool
        var ignoreDays: Int
        var previouslyMatchedEpisodes: Set<String>
        var lastMatch: Date?
        var feedURLs: [String] { Self.uniqueFeeds([feedURL] + additionalFeedURLs) }
        var displayName: String { name.isEmpty ? feedURL : name }
        var include: String
        var exclude: String
        var category: String
        var enabled: Bool
        var matchAll: Bool
        var maxItemsPerPoll: Int
        var tags: [String]
        var startPaused: Bool
        var sequential: Bool
        var queuePriority: Int

        private enum CodingKeys: String, CodingKey {
            case id, feedURL, include, exclude, category, enabled, matchAll, maxItemsPerPoll,
                 tags, startPaused, sequential, queuePriority, name, additionalFeedURLs,
                 episodeFilter, smartEpisodeFilter, downloadRepacks, ignoreDays,
                 previouslyMatchedEpisodes, lastMatch
        }

        init(id: UUID = UUID(),
             feedURL: String,
             include: String = "",
             exclude: String = "",
             category: String = "",
             enabled: Bool = true,
             matchAll: Bool = false,
             maxItemsPerPoll: Int = 50,
             tags: [String] = [],
             startPaused: Bool = false,
             sequential: Bool = false,
             queuePriority: Int = 0,
             name: String = "",
             additionalFeedURLs: [String] = [],
             episodeFilter: String = "",
             smartEpisodeFilter: Bool = false,
             downloadRepacks: Bool = false,
             ignoreDays: Int = 0) {
            self.id = id
            self.feedURL = feedURL
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.additionalFeedURLs = Self.uniqueFeeds(additionalFeedURLs).filter { $0 != feedURL }
            self.episodeFilter = episodeFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            self.smartEpisodeFilter = smartEpisodeFilter
            self.downloadRepacks = downloadRepacks
            self.ignoreDays = min(max(ignoreDays, 0), 3650)
            self.previouslyMatchedEpisodes = []
            self.lastMatch = nil
            self.include = include
            self.exclude = exclude
            self.category = category
            self.enabled = enabled
            self.matchAll = matchAll
            self.maxItemsPerPoll = min(max(maxItemsPerPoll, 1), 500)
            self.tags = Self.normalizedTags(tags)
            self.startPaused = startPaused
            self.sequential = sequential
            self.queuePriority = min(max(queuePriority, -1), 1)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(UUID.self, forKey: .id)
            self.feedURL = try container.decode(String.self, forKey: .feedURL)
            self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            self.additionalFeedURLs = try container.decodeIfPresent([String].self, forKey: .additionalFeedURLs) ?? []
            self.episodeFilter = try container.decodeIfPresent(String.self, forKey: .episodeFilter) ?? ""
            self.smartEpisodeFilter = try container.decodeIfPresent(Bool.self, forKey: .smartEpisodeFilter) ?? false
            self.downloadRepacks = try container.decodeIfPresent(Bool.self, forKey: .downloadRepacks) ?? false
            self.ignoreDays = min(max(try container.decodeIfPresent(Int.self, forKey: .ignoreDays) ?? 0, 0), 3650)
            self.previouslyMatchedEpisodes = try container.decodeIfPresent(Set<String>.self, forKey: .previouslyMatchedEpisodes) ?? []
            self.lastMatch = try container.decodeIfPresent(Date.self, forKey: .lastMatch)
            self.include = try container.decodeIfPresent(String.self, forKey: .include) ?? ""
            self.exclude = try container.decodeIfPresent(String.self, forKey: .exclude) ?? ""
            self.category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
            self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            self.matchAll = try container.decodeIfPresent(Bool.self, forKey: .matchAll) ?? false
            self.maxItemsPerPoll = min(max(try container.decodeIfPresent(Int.self, forKey: .maxItemsPerPoll) ?? 50, 1), 500)
            self.tags = Self.normalizedTags(try container.decodeIfPresent([String].self, forKey: .tags) ?? [])
            self.startPaused = try container.decodeIfPresent(Bool.self, forKey: .startPaused) ?? false
            self.sequential = try container.decodeIfPresent(Bool.self, forKey: .sequential) ?? false
            self.queuePriority = min(max(try container.decodeIfPresent(Int.self, forKey: .queuePriority) ?? 0, -1), 1)
        }

        static func uniqueFeeds(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }

        var validationError: String? {
            guard !feedURLs.isEmpty, feedURLs.allSatisfy({ value in
                guard let url = URL(string: value) else { return false }
                return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
                    && url.user == nil && url.password == nil
            }) else { return "Enter valid HTTP or HTTPS feed URLs, separated by commas or newlines." }
            guard RSSEpisodeFilter.selections(episodeFilter) != nil else {
                return "Use episode ranges such as 2x1-10; or 2x5-;. Separate ranges with semicolons."
            }
            return nil
        }

        func matchReason(title: String, now: Date = Date()) -> String? {
            if !enabled { return "Rule is disabled." }
            if let error = validationError { return error }
            guard DownloadsViewModel.rssRuleMatches(title: title, include: include, exclude: exclude, matchAll: matchAll)
                else { return "Title does not match the include/exclude filters." }
            guard RSSEpisodeFilter.matches(title, selection: episodeFilter) else { return "Episode is outside the selected range or cannot be recognized." }
            if ignoreDays > 0, let lastMatch, now.timeIntervalSince(lastMatch) < Double(ignoreDays) * 86400 {
                return "Rule is waiting for its cooldown to end." }
            if smartEpisodeFilter {
                let keys = RSSEpisodeFilter.keys(in: title)
                guard !keys.isEmpty else { return "No recognized episode number or date in the title." }
                let suffix = RSSEpisodeFilter.releaseSuffix(in: title)
                let pending = keys.contains { key in
                    if !previouslyMatchedEpisodes.contains(key) { return true }
                    return downloadRepacks && !suffix.isEmpty && !previouslyMatchedEpisodes.contains(key + suffix)
                }
                if !pending { return "Episode already matched by this rule." }
            }
            return nil
        }

        mutating func recordMatch(title: String, now: Date) {
            lastMatch = now
            if smartEpisodeFilter {
                for key in RSSEpisodeFilter.keys(in: title) {
                    previouslyMatchedEpisodes.insert(key)
                    let suffix = RSSEpisodeFilter.releaseSuffix(in: title)
                    if !suffix.isEmpty { previouslyMatchedEpisodes.insert(key + suffix) }
                    if suffix == "-REPACK-PROPER" {
                        previouslyMatchedEpisodes.insert(key + "-REPACK")
                        previouslyMatchedEpisodes.insert(key + "-PROPER")
                    }
                }
            }
        }

        static func normalizedTags(_ values: [String]) -> [String] {
            Array(Set(values.flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })).sorted()
        }
    }

    @Published private(set) var watchedFolderURL: URL?
    @Published private(set) var rssFeedURLs: [String]
    @Published private(set) var rssRules: [RSSRule]

    private let defaults: UserDefaults
    private static let watchedFolderBookmarkKey = "automation.watchedFolder.bookmark"
    private static let rssFeedsKey = "automation.rssFeeds"
    private static let rssRulesKey = "automation.rssRules"
    private var scopedURL: URL?

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        let legacyFeeds = defaults.stringArray(forKey: Self.rssFeedsKey) ?? []
        let decodedRules: [RSSRule]
        if let data = defaults.data(forKey: Self.rssRulesKey),
           let decoded = try? JSONDecoder().decode([RSSRule].self, from: data) {
            decodedRules = decoded
        } else {
            decodedRules = legacyFeeds.map { RSSRule(feedURL: $0) }
        }
        var migratedRules = decodedRules
        for feed in legacyFeeds where !migratedRules.contains(where: {
            $0.feedURLs.contains(feed)
        }) {
            migratedRules.append(RSSRule(feedURL: feed))
        }
        rssRules = migratedRules
        rssFeedURLs = RSSRule.uniqueFeeds(migratedRules.flatMap(\.feedURLs))
        watchedFolderURL = nil
        resolveWatchedFolder()
    }

    var watchedFolderDisplayName: String {
        watchedFolderURL?.path ?? "Not configured"
    }

    func chooseWatchedFolder() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Watched Folder"
        panel.message = "New .torrent files placed here will be added automatically."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = watchedFolderURL ?? DownloadLocationStore.systemDownloadsURL
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setWatchedFolder(url)
        }
#endif
    }

    func resetWatchedFolder() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        watchedFolderURL = nil
        defaults.removeObject(forKey: Self.watchedFolderBookmarkKey)
    }

    @discardableResult
    func setWatchedFolder(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let accessed = standardized.startAccessingSecurityScopedResource()
        do {
            let bookmark = try standardized.bookmarkData(options: [.withSecurityScope],
                                                          includingResourceValuesForKeys: nil,
                                                          relativeTo: nil)
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = accessed ? standardized : nil
            defaults.set(bookmark, forKey: Self.watchedFolderBookmarkKey)
            watchedFolderURL = standardized
            return true
        } catch {
            if accessed { standardized.stopAccessingSecurityScopedResource() }
            return false
        }
    }

    func addRSSFeed(_ rawURL: String) {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rssFeedURLs.contains(value) else { return }
        addRSSRule(feedURL: value)
    }

    @discardableResult
    func addRSSRule(feedURL: String,
                    include: String = "", exclude: String = "", category: String = "",
                    matchAll: Bool = false, maxItemsPerPoll: Int = 50, tags: [String] = [],
                    startPaused: Bool = false, sequential: Bool = false, queuePriority: Int = 0,
                    name: String = "", additionalFeedURLs: [String] = [], episodeFilter: String = "",
                    smartEpisodeFilter: Bool = false, downloadRepacks: Bool = false,
                    ignoreDays: Int = 0) -> UUID? {
        let rule = RSSRule(feedURL: feedURL.trimmingCharacters(in: .whitespacesAndNewlines),
                           include: include, exclude: exclude, category: category, matchAll: matchAll,
                           maxItemsPerPoll: maxItemsPerPoll, tags: tags, startPaused: startPaused,
                           sequential: sequential, queuePriority: queuePriority, name: name,
                           additionalFeedURLs: additionalFeedURLs, episodeFilter: episodeFilter,
                           smartEpisodeFilter: smartEpisodeFilter, downloadRepacks: downloadRepacks,
                           ignoreDays: ignoreDays)
        guard rule.validationError == nil else { return nil }
        rssRules.append(rule)
        persistRSSFeeds()
        return rule.id
    }

    @discardableResult
    func insertRSSRule(_ rule: RSSRule) -> Bool {
        guard rule.validationError == nil, !rssRules.contains(where: { $0.id == rule.id }) else { return false }
        rssRules.append(rule)
        persistRSSFeeds()
        return true
    }

    func removeRSSFeed(at offsets: IndexSet) {
        let removed = offsets.compactMap { rssFeedURLs.indices.contains($0) ? rssFeedURLs[$0] : nil }
        rssRules = rssRules.compactMap { original in
            var rule = original
            let feeds = rule.feedURLs.filter { !removed.contains($0) }
            guard let first = feeds.first else { return nil }
            rule.feedURL = first
            rule.additionalFeedURLs = Array(feeds.dropFirst())
            return rule
        }
        persistRSSFeeds()
    }

    func removeRSSRule(id: UUID) {
        rssRules.removeAll { $0.id == id }
        persistRSSFeeds()
    }

    @discardableResult
    func updateRSSRule(_ rule: RSSRule) -> Bool {
        guard rule.validationError == nil, let index = rssRules.firstIndex(where: { $0.id == rule.id }) else { return false }
        var updated = rule
        updated.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.tags = RSSRule.normalizedTags(rule.tags)
        updated.maxItemsPerPoll = min(max(rule.maxItemsPerPoll, 1), 500)
        updated.ignoreDays = min(max(rule.ignoreDays, 0), 3650)
        // An editor may have opened before another feed was imported. Never overwrite runtime history.
        updated.previouslyMatchedEpisodes = rssRules[index].previouslyMatchedEpisodes
        updated.lastMatch = rssRules[index].lastMatch
        rssRules[index] = updated
        persistRSSFeeds()
        return true
    }

    func moveRSSRule(id: UUID, offset: Int) {
        guard let index = rssRules.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(index + offset, 0), rssRules.count - 1)
        guard destination != index else { return }
        rssRules.insert(rssRules.remove(at: index), at: destination)
        persistRSSFeeds()
    }

    func resetRSSHistory(id: UUID) {
        guard let index = rssRules.firstIndex(where: { $0.id == id }) else { return }
        rssRules[index].previouslyMatchedEpisodes = []
        rssRules[index].lastMatch = nil
        persistRSSFeeds()
    }

    func recordRSSMatch(id: UUID, title: String, now: Date = Date()) {
        guard let index = rssRules.firstIndex(where: { $0.id == id }) else { return }
        rssRules[index].recordMatch(title: title, now: now)
        persistRSSFeeds()
    }

    func rules(for feedURL: String) -> [RSSRule] {
        rssRules.filter { $0.enabled && $0.feedURLs.contains(feedURL) }
    }

    func rule(for feedURL: String) -> RSSRule? { rules(for: feedURL).first }

    func matchingRule(feedURL: String, title: String, now: Date = Date(), counts: [UUID: Int] = [:]) -> RSSRule? {
        rules(for: feedURL).first { $0.matchReason(title: title, now: now) == nil
            && counts[$0.id, default: 0] < $0.maxItemsPerPoll }
    }

    private func persistRSSFeeds() {
        rssFeedURLs = RSSRule.uniqueFeeds(rssRules.flatMap(\.feedURLs))
        defaults.set(rssFeedURLs, forKey: Self.rssFeedsKey)
        if let data = try? JSONEncoder().encode(rssRules) {
            defaults.set(data, forKey: Self.rssRulesKey)
        }
    }

    private func resolveWatchedFolder() {
        guard let bookmark = defaults.data(forKey: Self.watchedFolderBookmarkKey) else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            guard url.isFileURL, url.startAccessingSecurityScopedResource() else { return }
            scopedURL = url.standardizedFileURL
            watchedFolderURL = scopedURL
            if isStale { _ = setWatchedFolder(scopedURL!) }
        } catch {
            defaults.removeObject(forKey: Self.watchedFolderBookmarkKey)
        }
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
    }
}
