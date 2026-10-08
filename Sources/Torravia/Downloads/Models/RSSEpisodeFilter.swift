import TorraviaSearchCore
import Foundation

/// RSS title parsing and explicit season/episode selection. Does not inspect media files.
nonisolated enum RSSEpisodeFilter {
    struct Episode: Equatable, Sendable {
        let season: Int
        let number: Int
        var key: String { "\(season)x\(number)" }
    }

    struct Selection: Sendable {
        let season: Int
        let first: Int
        let last: Int?
        func contains(_ episode: Episode) -> Bool {
            // An open range follows the series into later seasons.
            if last == nil, episode.season > season { return true }
            return episode.season == season && episode.number >= first
                && (last.map { episode.number <= $0 } ?? true)
        }
    }

    static func selections(_ raw: String) -> [Selection]? {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let regex = try! NSRegularExpression(pattern: #"^(\d{1,4})x(\d{1,4})(?:-(\d{1,4})?)?$"#, options: [.caseInsensitive])
        var result: [Selection] = []
        for part in raw.split(separator: ";", omittingEmptySubsequences: true) {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let season = integer(match, 1, text), let first = integer(match, 2, text) else { return nil }
            let last = text.hasSuffix("-") ? nil : (integer(match, 3, text) ?? first)
            if let last, last < first { return nil }
            result.append(Selection(season: season, first: first, last: last))
        }
        return result.isEmpty ? nil : result
    }

    static func episodes(in title: String) -> [Episode] {
        // Accept S02E05, S02E05E06, S02E05-E07, 2x05 and 2x05-07.
        let regex = try! NSRegularExpression(pattern: #"\b(?:s(\d{1,4})[ ._-]?e(\d{1,4})|(\d{1,4})x(\d{1,4}))(-(?:e)?\d{1,4}(?![a-z0-9])|(?:e\d{1,4})*)(?!\d)"#, options: [.caseInsensitive])
        let range = NSRange(title.startIndex..., in: title)
        return regex.matches(in: title, range: range).flatMap { match -> [Episode] in
            guard let season = integer(match, 1, title) ?? integer(match, 3, title),
                  let first = integer(match, 2, title) ?? integer(match, 4, title),
                  let suffixRange = Range(match.range(at: 5), in: title) else { return [] }
            let suffix = String(title[suffixRange]).lowercased()
            var numbers = [first]
            if suffix.hasPrefix("-") {
                guard let last = Int(suffix.dropFirst().replacingOccurrences(of: "e", with: "")),
                      last >= first, last - first <= 100 else { return [] }
                numbers = Array(first...last)
            } else {
                numbers += suffix.split(separator: "e").compactMap { Int($0) }
            }
            return numbers.map { Episode(season: season, number: $0) }
        }
    }

    static func keys(in title: String) -> [String] {
        let episodes = episodes(in: title)
        if !episodes.isEmpty { return Array(Set(episodes.map(\.key))).sorted() }
        // Date-based episodes use a canonical ISO date, validating month/day combinations.
        let patterns = [#"\b(\d{4})[.-](\d{1,2})[.-](\d{1,2})\b"#,
                        #"\b(\d{1,2})[.-](\d{1,2})[.-](\d{4})\b"#]
        for (index, pattern) in patterns.enumerated() {
            let regex = try! NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
                  let a = integer(match, 1, title), let month = integer(match, 2, title),
                  let c = integer(match, 3, title) else { continue }
            let year = index == 0 ? a : c, day = index == 0 ? c : a
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = DateComponents(year: year, month: month, day: day)
            guard let date = calendar.date(from: components),
                  calendar.dateComponents([.year, .month, .day], from: date) == components else { continue }
            return [String(format: "%04d-%02d-%02d", year, month, day)]
        }
        return []
    }

    static func matches(_ title: String, selection raw: String) -> Bool {
        guard let selections = selections(raw) else { return false }
        if selections.isEmpty { return true }
        let episodes = episodes(in: title)
        return !episodes.isEmpty && episodes.allSatisfy { episode in selections.contains { $0.contains(episode) } }
    }

    static func releaseSuffix(in title: String) -> String {
        let tokens = title.uppercased().split { !$0.isLetter && !$0.isNumber }
        return (tokens.contains("REPACK") ? "-REPACK" : "")
            + (tokens.contains("PROPER") ? "-PROPER" : "")
    }

    private static func integer(_ match: NSTextCheckingResult, _ group: Int, _ text: String) -> Int? {
        guard let range = Range(match.range(at: group), in: text) else { return nil }
        return Int(text[range])
    }
}
