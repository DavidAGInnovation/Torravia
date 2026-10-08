import TorraviaSearchCore
import Foundation

struct AcademicTorrentsSearchProvider: TorrentSearchProviding {
    private let session: URLSession
    private let trackers: [String]
    private let databaseURL = URL(string: "https://academictorrents.com/database.xml")!
    private let maxResults = 40

    init(session: URLSession, trackers: [String]) {
        self.session = session
        self.trackers = trackers
    }

    func search(query: String) async throws -> [TorrentItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let (data, response) = try await session.providerData(from: databaseURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HTTPStatusError(url: databaseURL, statusCode: httpResponse.statusCode)
        }
        guard !data.isEmpty else { return [] }

        let tokens = trimmed.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        let parser = AcademicDatabaseParser(data: data, tokens: tokens)
        var entries = try parser.parse()

        if entries.isEmpty { return [] }
        if entries.count > maxResults {
            entries = Array(entries.prefix(maxResults))
        }

        // The database already contains the info hash for every matching
        // entry. Detail pages are useful for swarm statistics, but they are
        // not required to build a valid result and can be temporarily slow.
        // Keep the source row when a detail request fails instead of dropping
        // it (or aborting the whole provider search).
        return await withTaskGroup(of: TorrentItem?.self,
                                   returning: [TorrentItem].self) { group in
            for entry in entries {
                group.addTask { @MainActor in
                    let detail: (magnet: String?, seeders: Int, leechers: Int)?
                    if let detailURL = entry.detailURL {
                        detail = try? await self.fetchDetails(detailURL: detailURL)
                    } else {
                        detail = nil
                    }
                    let magnet = detail?.magnet
                        ?? buildMagnetLink(infoHash: entry.infoHash,
                                           title: entry.title,
                                           trackers: self.trackers)
                    guard let magnet else { return nil }

                    return TorrentItem(title: entry.title,
                                      seeders: detail?.seeders ?? 0,
                                      leechers: detail?.leechers ?? 0,
                                      sizeBytes: entry.sizeBytes,
                                      magnetLink: magnet,
                                      sourceURL: entry.detailURL,
                                      source: "Academic Torrents")
                }
            }

            var items: [TorrentItem] = []
            items.reserveCapacity(entries.count)
            for await item in group {
                if let item { items.append(item) }
            }
            return items
        }
    }

    private func fetchDetails(detailURL: URL) async throws -> (magnet: String?, seeders: Int, leechers: Int) {
        let (data, response) = try await session.providerData(from: detailURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HTTPStatusError(url: detailURL, statusCode: httpResponse.statusCode)
        }
        guard !data.isEmpty else { return (nil, 0, 0) }

        guard let html = String(data: data, encoding: .utf8) else { return (nil, 0, 0) }
        if containsCloudflareBlock(in: html) {
            throw buildProviderError(site: "Academic Torrents", message: "Blocked by Cloudflare while loading details.")
        }

        let magnetRaw = firstMatch(in: html, pattern: #"id="magnetlink"[^>]*href="(magnet:[^"]+)""#)
        let magnet = magnetRaw.map(decodeHTMLEntities)

        if let groups = matchGroups(in: html, pattern: #"([0-9]+)\s+complete,\s+([0-9]+)\s+downloading"#) {
            let seeders = groups[safe: 0].flatMap(Int.init) ?? 0
            let leechers = groups[safe: 1].flatMap(Int.init) ?? 0
            return (magnet, seeders, leechers)
        }

        if let groups = matchGroups(in: html, pattern: #"class="badge">([0-9]+)/([0-9]+)<"#) {
            let seeders = groups[safe: 0].flatMap(Int.init) ?? 0
            let leechers = groups[safe: 1].flatMap(Int.init) ?? 0
            return (magnet, seeders, leechers)
        }

        return (magnet, 0, 0)
    }
}

final class AcademicDatabaseParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let tokens: [String]
    private var results: [AcademicTorrentIndexEntry] = []
    private var currentItem: AcademicItemBuilder?
    private var currentElement: String?
    private var currentText: String = ""

    init(data: Data, tokens: [String]) {
        self.data = data
        self.tokens = tokens
        super.init()
    }

    func parse() throws -> [AcademicTorrentIndexEntry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            if let error = parser.parserError {
                throw error
            }
            return results
        }
        return results
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = (qName ?? elementName).lowercased()
        if element == "item" {
            currentItem = AcademicItemBuilder()
            currentElement = nil
            currentText = ""
            return
        }

        guard currentItem != nil else { return }
        currentElement = element
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentItem != nil else { return }
        currentText.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = (qName ?? elementName).lowercased()

        guard let builder = currentItem else { return }

        if element == "item" {
            if let entry = builder.build(tokens: tokens) {
                results.append(entry)
            }
            currentItem = nil
            currentElement = nil
            currentText = ""
            return
        }

        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            currentElement = nil
            currentText = ""
            return
        }

        switch element {
        case "title":
            builder.title.append(contentsOf: trimmed)
        case "description":
            if !builder.descriptionText.isEmpty {
                builder.descriptionText.append(" ")
            }
            builder.descriptionText.append(contentsOf: trimmed)
        case "infohash":
            builder.infoHash = trimmed
        case "guid":
            if builder.link.isEmpty {
                builder.link = trimmed
            }
        case "link":
            if builder.link.isEmpty {
                builder.link = trimmed
            }
        case "size":
            builder.size = trimmed
        default:
            break
        }

        currentElement = nil
        currentText = ""
    }
}

final class AcademicItemBuilder {
    var title: String = ""
    var descriptionText: String = ""
    var infoHash: String = ""
    var link: String = ""
    var size: String = ""

    func build(tokens: [String]) -> AcademicTorrentIndexEntry? {
        guard let hash = infoHash.nonEmpty else { return nil }

        if !tokens.isEmpty {
            let haystack = (title + " " + descriptionText).lowercased()
            for token in tokens where !haystack.contains(token) {
                return nil
            }
        }

        let normalizedTitle = decodeHTMLEntities(title).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = decodeHTMLEntities(descriptionText)
        let sizeBytes = Int64(size.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let detailURL = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))

        return AcademicTorrentIndexEntry(title: normalizedTitle.isEmpty ? hash : normalizedTitle,
                                         description: normalizedDescription,
                                         infoHash: hash,
                                         sizeBytes: sizeBytes,
                                         detailURL: detailURL)
    }
}

struct AcademicTorrentIndexEntry {
    let title: String
    let description: String
    let infoHash: String
    let sizeBytes: Int64
    let detailURL: URL?
}
