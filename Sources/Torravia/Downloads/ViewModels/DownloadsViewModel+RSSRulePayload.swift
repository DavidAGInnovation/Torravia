import Foundation

@MainActor
extension DownloadsViewModel {
    func remoteRSSRule(_ body: [String: Any], existing: DownloadAutomationStore.RSSRule? = nil) throws -> DownloadAutomationStore.RSSRule {
        var rule = existing ?? DownloadAutomationStore.RSSRule(feedURL: "")
        func invalid(_ message: String) -> NSError { NSError(domain: "RSSRule", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        func strings(_ key: String) throws -> [String]? {
            guard let value = body[key] else { return nil }
            if let list = value as? [String] { return list }
            if let text = value as? String { return text.split { $0 == "," || $0 == "\n" }.map(String.init) }
            throw invalid("\(key) must be a string or a list of strings.")
        }
        if let feeds = try strings("feedURLs") {
            let normalized = DownloadAutomationStore.RSSRule.uniqueFeeds(feeds)
            rule.feedURL = normalized.first ?? ""
            rule.additionalFeedURLs = Array(normalized.dropFirst())
        } else if let value = body["feedURL"] {
            guard let text = value as? String else { throw invalid("feedURL must be a string.") }
            rule.feedURL = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let texts: [(String, WritableKeyPath<DownloadAutomationStore.RSSRule, String>)] = [
            ("name", \.name), ("include", \.include), ("exclude", \.exclude), ("category", \.category), ("episodeFilter", \.episodeFilter)]
        for (key, path) in texts {
            if let value = body[key] {
                guard let text = value as? String else { throw invalid("\(key) must be a string.") }
                rule[keyPath: path] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let flags: [(String, WritableKeyPath<DownloadAutomationStore.RSSRule, Bool>)] = [
            ("enabled", \.enabled), ("matchAll", \.matchAll), ("startPaused", \.startPaused), ("sequential", \.sequential),
            ("smartEpisodeFilter", \.smartEpisodeFilter), ("downloadRepacks", \.downloadRepacks)]
        for (key, path) in flags {
            if let value = body[key] {
                guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw invalid("\(key) must be a boolean.") }
                rule[keyPath: path] = flag.boolValue
            }
        }
        let numbers: [(String, WritableKeyPath<DownloadAutomationStore.RSSRule, Int>, ClosedRange<Int>)] = [
            ("maxItemsPerPoll", \.maxItemsPerPoll, 1...500), ("ignoreDays", \.ignoreDays, 0...3650), ("queuePriority", \.queuePriority, -1...1)]
        for (key, path, range) in numbers {
            if let value = body[key] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                      range.contains(number.intValue) else { throw invalid("\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).") }
                rule[keyPath: path] = number.intValue
            }
        }
        if let tags = try strings("tags") { rule.tags = DownloadAutomationStore.RSSRule.normalizedTags(tags) }
        if let error = rule.validationError { throw invalid(error) }
        return rule
    }
}
