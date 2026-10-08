//
//  TorrentItem.swift
//  Torravia
//
//

import Foundation

/// Preserve existing percent escapes when providers leave display-name
/// characters unescaped. Foundation's automatic URL repair can encode the
/// entire query again, including valid tracker and info-hash escapes.
nonisolated public enum MagnetLink {
    public static func components(_ link: String) -> URLComponents? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: "?"),
              trimmed[..<separator].lowercased() == "magnet:",
              let query = String(trimmed[trimmed.index(after: separator)...])
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(CharacterSet(charactersIn: "%"))) else {
            return nil
        }
        return URLComponents(string: "magnet:?" + query, encodingInvalidCharacters: false)
    }
}

public struct TorrentItem: Identifiable, Hashable, Codable {
    public let id: UUID
    public let title: String
    public let seeders: Int
    public let leechers: Int
    public let sizeBytes: Int64
    public let magnetLink: String
    public let sourceURL: URL?
    public let source: String?

    public init(id: UUID = UUID(),
         title: String,
         seeders: Int,
         leechers: Int,
         sizeBytes: Int64,
         magnetLink: String,
         sourceURL: URL? = nil,
         source: String? = nil) {
        self.id = id
        self.title = title
        self.seeders = seeders
        self.leechers = leechers
        self.sizeBytes = sizeBytes
        self.magnetLink = magnetLink
        self.sourceURL = sourceURL
        self.source = source
    }
}

extension TorrentItem {
    public func replacingMagnetLink(with magnetLink: String) -> TorrentItem {
        TorrentItem(id: id,
                    title: title,
                    seeders: seeders,
                    leechers: leechers,
                    sizeBytes: sizeBytes,
                    magnetLink: magnetLink,
                    sourceURL: sourceURL,
                    source: source)
    }

    public func replacingTitle(with title: String) -> TorrentItem {
        TorrentItem(id: id,
                    title: title,
                    seeders: seeders,
                    leechers: leechers,
                    sizeBytes: sizeBytes,
                    magnetLink: magnetLink,
                    sourceURL: sourceURL,
                    source: source)
    }

    public func merging(_ candidate: TorrentItem) -> TorrentItem {
        let updatedTitle: String
        let currentTitleIsPlaceholder = Self.isPlaceholderTitle(title)
        let candidateTitleIsPlaceholder = Self.isPlaceholderTitle(candidate.title)
        if currentTitleIsPlaceholder && !candidateTitleIsPlaceholder {
            updatedTitle = candidate.title
        } else if !currentTitleIsPlaceholder && candidateTitleIsPlaceholder {
            updatedTitle = title
        } else if title.caseInsensitiveCompare(candidate.title) == .orderedSame {
            updatedTitle = title
        } else {
            updatedTitle = title.count >= candidate.title.count ? title : candidate.title
        }

        let updatedSeeders = max(seeders, candidate.seeders)
        let updatedLeechers = max(leechers, candidate.leechers)

        let updatedSize: Int64
        switch (sizeBytes > 0, candidate.sizeBytes > 0) {
        case (true, true):
            updatedSize = max(sizeBytes, candidate.sizeBytes)
        case (true, false):
            updatedSize = sizeBytes
        case (false, true):
            updatedSize = candidate.sizeBytes
        default:
            updatedSize = 0
        }

        let updatedSourceURL = sourceURL ?? candidate.sourceURL
        let combinedSource = mergeSources(primary: source, secondary: candidate.source)
        var updatedMagnet = magnetLink
        if let identity = TorrentMetadata.canonicalMagnetIdentity(magnetLink),
           identity == TorrentMetadata.canonicalMagnetIdentity(candidate.magnetLink),
           var components = MagnetLink.components(magnetLink),
           let extra = MagnetLink.components(candidate.magnetLink)?.queryItems {
            var items = components.queryItems ?? []
            var trackers = Set(items.filter { $0.name.lowercased() == "tr" }.compactMap(\.value))
            for item in extra where item.name.lowercased() == "tr" {
                guard let tracker = item.value, !tracker.isEmpty, trackers.insert(tracker).inserted else { continue }
                items.append(URLQueryItem(name: "tr", value: tracker))
            }
            components.queryItems = items
            updatedMagnet = components.string ?? magnetLink
        }

        return TorrentItem(id: id,
                           title: updatedTitle,
                           seeders: updatedSeeders,
                           leechers: updatedLeechers,
                           sizeBytes: updatedSize,
                           magnetLink: updatedMagnet,
                           sourceURL: updatedSourceURL,
                           source: combinedSource)
    }

    private static func isPlaceholderTitle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("magnet:")
    }

    private func mergeSources(primary: String?, secondary: String?) -> String? {
        var ordered: [String] = []

        func appendComponents(from value: String?) {
            guard let value else { return }
            let parts = value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for part in parts where !ordered.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
                ordered.append(part)
            }
        }

        appendComponents(from: primary)
        appendComponents(from: secondary)

        guard !ordered.isEmpty else { return nil }
        return ordered.joined(separator: ", ")
    }
}
