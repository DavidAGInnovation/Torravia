import TorraviaSearchCore
//
//  DownloadsViewModel+Automation.swift
//  Torravia
//

import Foundation

@MainActor
extension DownloadsViewModel {
    func startAutomation() {
        automationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.scanWatchedFolder()
            await self.pollRSSFeeds()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                } catch { return }
                await self.scanWatchedFolder()
                if Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 300) < 20 {
                    await self.pollRSSFeeds()
                }
            }
        }
    }

    private func scanWatchedFolder() async {
        guard let folder = automation.watchedFolderURL else { return }
        guard let enumerator = FileManager.default.enumerator(at: folder,
                                                               includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        let urls = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "torrent" }
            .sorted { $0.path < $1.path }
        for url in urls {
            let key = url.standardizedFileURL.path
            guard !importedWatchedFiles.contains(key) else { continue }
            importedWatchedFiles.insert(key)
            let result = await addTorrentFile(at: url)
            if case .failed = result {
                importedWatchedFiles.remove(key)
            }
        }
        if importedWatchedFiles.count > 1_000 {
            importedWatchedFiles = Set(urls.map { $0.standardizedFileURL.path })
        }
    }

    func refreshRSSFeeds() {
        Task(priority: .userInitiated) { [weak self] in
            await self?.pollRSSFeeds()
        }
    }

    func pollRSSFeeds(session rssSession: URLSession = .shared) async {
        guard !rssPollInProgress, !automation.rssFeedURLs.isEmpty else { return }
        rssPollInProgress = true
        defer { rssPollInProgress = false }
        var ruleImportCounts: [UUID: Int] = [:]
        rssCachedFeedData = rssCachedFeedData.filter { automation.rssFeedURLs.contains($0.key) }
        for feedURLString in automation.rssFeedURLs {
            guard let url = URL(string: feedURLString) else { continue }
            guard !automation.rules(for: feedURLString).isEmpty else { continue }
            do {
                var request = URLRequest(url: url,
                                         cachePolicy: .reloadIgnoringLocalCacheData,
                                         timeoutInterval: 30)
                request.setValue("Torravia RSS/1.0", forHTTPHeaderField: "User-Agent")
                if rssCachedFeedData[feedURLString] != nil, let state = rssFeedStates[feedURLString] {
                    if let etag = state.etag, !etag.isEmpty {
                        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
                    }
                    if let lastModified = state.lastModified, !lastModified.isEmpty {
                        request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
                    }
                }
                let (responseData, response) = try await rssSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    rssFeedStates[feedURLString, default: RSSFeedState()].lastError = "The feed returned an invalid response."
                    continue
                }
                guard (200..<300).contains(http.statusCode) || (http.statusCode == 304 && rssCachedFeedData[feedURLString] != nil) else {
                    var state = rssFeedStates[feedURLString, default: RSSFeedState()]
                    state.lastPolledAt = Date()
                    state.lastError = "Feed returned HTTP \(http.statusCode)."
                    rssFeedStates[feedURLString] = state
                    continue
                }
                let data = http.statusCode == 304 ? rssCachedFeedData[feedURLString]! : responseData
                if http.statusCode != 304 { rssCachedFeedData[feedURLString] = data }
                var state = rssFeedStates[feedURLString, default: RSSFeedState()]
                if http.statusCode != 304 {
                    state.etag = http.value(forHTTPHeaderField: "ETag")
                    state.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
                }
                state.lastPolledAt = Date()
                state.lastError = nil
                let items = RSSFeedParser.parse(data: data)
                state.itemCount = items.count
                rssFeedStates[feedURLString] = state
                for item in items {
                    let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let rule = automation.matchingRule(feedURL: feedURLString, title: title,
                                                             counts: ruleImportCounts) else { continue }
                    // Scope the dedupe key to its feed. The same GUID is often
                    // reused by different feeds and must not suppress a valid
                    // import from another source.
                    let itemIdentity = item.guid ?? item.link ?? item.title
                    let key = feedURLString + "|" + itemIdentity
                    guard !key.isEmpty,
                          !importedRSSItems.contains(key) else { continue }
                    if let link = item.link, Self.isValidMagnetLink(link) {
                        importedRSSItems.insert(key)
                        persistImportedRSSItems()
                        if let id = addMagnetLink(link, title: title, category: rule.category) {
                            applyRSSRule(rule, to: id)
                            automation.recordRSSMatch(id: rule.id, title: title)
                            ruleImportCounts[rule.id, default: 0] += 1
                            state.importedCount += 1
                        } else {
                            importedRSSItems.remove(key)
                            persistImportedRSSItems()
                        }
                        continue
                    }
                    guard let enclosure = item.enclosure,
                          let enclosureURL = URL(string: enclosure),
                          ["http", "https"].contains(enclosureURL.scheme?.lowercased() ?? "") else { continue }
                    do {
                        let (torrentData, response) = try await rssSession.data(from: enclosureURL)
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                        let summary = try await Task.detached(priority: .utility) {
                            try Self.parseTorrentFile(data: torrentData)
                        }.value
                        guard let summary, let magnet = summary.magnetLink else { continue }
                        // Fetching/parsing may suspend while the rule is edited. Choose again before queueing.
                        guard let currentRule = automation.matchingRule(feedURL: feedURLString, title: title,
                                                                         counts: ruleImportCounts) else { continue }
                        let torrent = TorrentItem(title: summary.name, seeders: 0, leechers: 0,
                                                  sizeBytes: summary.totalSize ?? Int64(summary.rawSize), magnetLink: magnet)
                        guard add(from: torrent, torrentData: torrentData, torrentFileName: enclosureURL.lastPathComponent,
                                  category: currentRule.category), let id = downloads.last?.id else { continue }
                        importedRSSItems.insert(key)
                        persistImportedRSSItems()
                        applyRSSRule(currentRule, to: id)
                        automation.recordRSSMatch(id: currentRule.id, title: title)
                        ruleImportCounts[currentRule.id, default: 0] += 1
                        state.importedCount += 1
                    } catch {
                        // Leave failed items eligible for the next poll.
                    }
                }
                rssFeedStates[feedURLString] = state
            } catch {
                var state = rssFeedStates[feedURLString, default: RSSFeedState()]
                state.lastPolledAt = Date()
                state.lastError = error.localizedDescription
                rssFeedStates[feedURLString] = state
            }
        }
        if importedRSSItems.count > 2_000 {
            importedRSSItems = Set(importedRSSItems.suffix(1_000))
            persistImportedRSSItems()
        }
    }

    private func applyRSSRule(_ rule: DownloadAutomationStore.RSSRule, to downloadID: UUID) {
        guard let download = downloads.first(where: { $0.id == downloadID }) else { return }
        if !rule.tags.isEmpty {
            updateMetadata(for: downloadID,
                           category: download.category,
                           tags: Array(Set(download.tags + rule.tags)).sorted())
        }
        if rule.sequential {
            setSequentialDownload(true, for: download)
        }
        if rule.queuePriority != 0 {
            update(downloadID: downloadID) { $0.queuePriority = rule.queuePriority }
            if rule.queuePriority > 0 {
                moveToTop(download)
            } else {
                moveToBottom(download)
            }
        }
        if rule.startPaused {
            pause(download)
        }
    }

    private func persistImportedRSSItems() {
        UserDefaults.standard.set(Array(importedRSSItems).sorted(), forKey: Self.importedRSSItemsKey)
    }

    /// RSS filters accept comma/newline-separated regular expressions. Invalid
    /// expressions fall back to a case-insensitive literal match so an old
    /// term list can never stop the feed importer.
    nonisolated static func rssRuleMatches(title: String,
                                           include: String,
                                           exclude: String,
                                           matchAll: Bool = false) -> Bool {
        let patterns = { (raw: String) -> [String] in
            raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let matches: (String) -> Bool = { pattern in
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(title.startIndex..<title.endIndex, in: title)
                return regex.firstMatch(in: title, options: [], range: range) != nil
            }
            return title.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        let includePatterns = patterns(include)
        let excludePatterns = patterns(exclude)
        let includeMatches = includePatterns.isEmpty
            || (matchAll ? includePatterns.allSatisfy(matches) : includePatterns.contains(where: matches))
        let excluded = excludePatterns.contains(where: matches)
        return includeMatches && !excluded
    }
}
