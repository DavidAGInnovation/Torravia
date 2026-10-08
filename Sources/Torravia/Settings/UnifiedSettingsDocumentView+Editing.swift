#if os(macOS)
import AppKit

extension UnifiedSettingsDocumentView {
    func readRSSDraft() -> DownloadAutomationStore.RSSRule {
        let feeds = (fields["rssFeed"]?.stringValue ?? "").split { $0 == "," || $0 == "\n" }.map(String.init)
        var rule = DownloadAutomationStore.RSSRule(id: editingRSSRuleID ?? rssDraft?.id ?? UUID(),
            feedURL: feeds.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            include: fields["rssInclude"]?.stringValue ?? "",
            exclude: fields["rssExclude"]?.stringValue ?? "",
            category: fields["rssCategory"]?.stringValue ?? "",
            matchAll: rssMatchAll,
            maxItemsPerPoll: Int(fields["rssMaxItems"]?.stringValue ?? "50") ?? 50,
            tags: (fields["rssTags"]?.stringValue ?? "").split(separator: ",").map(String.init),
            startPaused: rssStartPaused, sequential: rssSequential, queuePriority: rssQueuePriority,
            name: fields["rssName"]?.stringValue ?? "", additionalFeedURLs: Array(feeds.dropFirst()),
            episodeFilter: fields["rssEpisodes"]?.stringValue ?? "",
            smartEpisodeFilter: rssSmartEpisodes, downloadRepacks: rssDownloadRepacks,
            ignoreDays: Int(fields["rssIgnoreDays"]?.stringValue ?? "0") ?? 0)
        if let existing = automation.rssRules.first(where: { $0.id == editingRSSRuleID }) {
            rule.previouslyMatchedEpisodes = existing.previouslyMatchedEpisodes
            rule.lastMatch = existing.lastMatch
            rule.enabled = existing.enabled
        }
        return rule
    }

    func addRSSRule() {
        guard let maximum = Int(fields["rssMaxItems"]?.stringValue ?? ""), (1...500).contains(maximum),
              let days = Int(fields["rssIgnoreDays"]?.stringValue ?? ""), (0...3650).contains(days) else {
            rssRuleError = "Enter 1–500 imports per poll and a cooldown of 0–3650 whole days."
            refreshAfterAction()
            return
        }
        let rule = readRSSDraft()
        if let error = rule.validationError { rssRuleError = error; refreshAfterAction(); return }
        if editingRSSRuleID != nil {
            guard automation.updateRSSRule(rule) else {
                rssRuleError = "This rule was removed. Cancel editing and add it again."
                refreshAfterAction()
                return
            }
        } else {
            automation.addRSSRule(feedURL: rule.feedURL, include: rule.include, exclude: rule.exclude,
                category: rule.category, matchAll: rule.matchAll, maxItemsPerPoll: rule.maxItemsPerPoll,
                tags: rule.tags, startPaused: rule.startPaused, sequential: rule.sequential,
                queuePriority: rule.queuePriority, name: rule.name, additionalFeedURLs: rule.additionalFeedURLs,
                episodeFilter: rule.episodeFilter, smartEpisodeFilter: rule.smartEpisodeFilter,
                downloadRepacks: rule.downloadRepacks, ignoreDays: rule.ignoreDays)
        }
        resetRSSDraft()
    }

    func resetRSSDraft(_ rule: DownloadAutomationStore.RSSRule? = nil) {
        editingRSSRuleID = rule?.id
        rssDraft = rule
        rssRuleError = nil
        rssPreviewResult = nil
        rssPreviewTitle = ""
        rssStartPaused = rule?.startPaused ?? false
        rssSequential = rule?.sequential ?? false
        rssMatchAll = rule?.matchAll ?? false
        rssQueuePriority = rule?.queuePriority ?? 0
        rssSmartEpisodes = rule?.smartEpisodeFilter ?? false
        rssDownloadRepacks = rule?.downloadRepacks ?? false
        fields.removeAll() // The next rebuild uses the selected draft, not the previous form.
        rebuildDocument(preserveScroll: false)
    }

    func previewRSSRule() {
        let rule = readRSSDraft()
        let title = fields["rssPreview"]?.stringValue ?? ""
        let keys = RSSEpisodeFilter.keys(in: title)
        rssPreviewResult = title.isEmpty ? "Enter a sample release title first."
            : (rule.matchReason(title: title) ?? "Matches this rule.")
                + (keys.isEmpty ? "" : " Episode: " + keys.joined(separator: ", "))
        refreshAfterAction()
    }

    func confirmRSSHistoryReset(id: UUID) {
        let alert = NSAlert()
        alert.messageText = "Reset this rule's episode history?"
        alert.informativeText = "Clears remembered episodes and the cooldown. New feed entries for these episodes can match again. Already imported feed entries stay skipped."
        alert.addButton(withTitle: "Reset History")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { automation.resetRSSHistory(id: id); refreshAfterAction() }
    }

    @objc func fieldCommitted(_ sender: NSTextField) { updateField(sender) }
    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { updateField(field) }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let value = link as? URL {
            url = value
        } else if let value = link as? String {
            url = URL(string: value)
        } else {
            url = nil
        }
        guard let url else { return false }
        return NSWorkspace.shared.open(url)
    }

    private func updateField(_ field: NSTextField) {
        switch field.identifier?.rawValue {
        case "remoteHostname": preferences.remoteControlHostname = field.stringValue
        case "networkInterface": preferences.networkInterface = field.stringValue
        case "i2pHost": preferences.i2pHost = field.stringValue
        case "proxyHost": preferences.proxyHost = field.stringValue
        case "proxyUsername": preferences.proxyUsername = field.stringValue
        case "proxyPassword": preferences.proxyPassword = field.stringValue
        default: break
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let value = notification.object as? NSTextView else { return }
        switch value.identifier?.rawValue {
        case "additionalTrackers": preferences.additionalTrackerURLs = value.string
        case "blockedIPRanges": preferences.blockedIPRanges = value.string
        default: break
        }
    }
}

#endif
