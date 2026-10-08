import TorraviaSearchCore
import Foundation

struct SearchProvider: TorrentSearchProviding {
    struct NamedProvider {
        let name: String
        let provider: any TorrentSearchProviding
        var minimumTimeout: Double = 0
    }

    private let providers: [NamedProvider]
    private let maxResults: Int
    private let tuning: SearchTuning

    init(mode: SearchMode = .fast,
         sessionConfiguration: URLSessionConfiguration? = nil,
         maxResults: Int? = nil,
         enabledSites: Set<TorrentSearchSite>? = nil) {
        self.tuning = mode.tuning
        let configuration: URLSessionConfiguration
        if let sessionConfiguration {
            configuration = sessionConfiguration
        } else {
            configuration = Self.sessionConfiguration(mode: mode)
        }

        let session = URLSession(configuration: configuration)
        // Search results should preserve trackers supplied by the source, but
        // synthesized magnets remain tracker-neutral. The native session can
        // add the refreshed list later if the download is genuinely stalled.
        let trackers: [String] = []
        let requestedSites = enabledSites ?? TorrentSearchSite.defaultEnabled
        let providerList = TorrentSearchSite.defaultOrder
            .filter { requestedSites.contains($0) }
            .compactMap { $0.namedProvider(session: session, trackers: trackers) }
        self.providers = providerList
        self.maxResults = maxResults ?? tuning.maxResults
    }

    static func sessionConfiguration(mode: SearchMode) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = mode.tuning.requestTimeout
        config.timeoutIntervalForResource = mode.tuning.resourceTimeout
        config.httpAdditionalHeaders = ["User-Agent": "Torravia/1.0 (macOS)"]
        return config
    }

    nonisolated static let availabilityQuery = "healthcheck"

    /// Run the same provider, discovery, request headers, and response parser
    /// as a user search. A status page alone cannot establish availability.
    static func checkAvailability(for site: TorrentSearchSite, session: URLSession, context: (any ProviderRequestContext)? = nil) async throws {
        try Task.checkCancellation()
        guard let entry = site.namedProvider(session: session, trackers: [], context: context, isAvailabilityCheck: true) else {
            throw URLError(.unsupportedURL)
        }
        let timeout = max(entry.minimumTimeout, SearchMode.balanced.tuning.providerTimeoutSeconds)
        switch await outcome(for: entry, query: availabilityQuery, timeout: timeout) {
        case .success:
            try Task.checkCancellation()
        case .failure(let failure):
            throw failure.underlying
        case nil:
            throw CancellationError()
        }
    }

    init(providers: [(name: String, provider: any TorrentSearchProviding)], maxResults: Int = 120) {
        self.providers = providers.map { NamedProvider(name: $0.name, provider: $0.provider) }
        self.maxResults = maxResults
        self.tuning = SearchMode.balanced.tuning
    }

    func search(query: String) async throws -> [TorrentItem] {
        try await search(query: query, onResults: nil)
    }

    /// Publish usable results as each site finishes, without waiting for the
    /// slowest site. Tracker-ranked consumers request all candidates and apply
    /// the display limit only after checking and sorting the displayed counts.
    func search(query: String, finishWhenFull: Bool = true, limitResults: Bool = true,
                onProviderResult: (@MainActor (String, Error?) -> Void)? = nil,
                onResults: (@MainActor ([TorrentItem]) -> Void)?) async throws -> [TorrentItem] {
        try Task.checkCancellation()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var aggregated: [TorrentItem] = []
        aggregated.reserveCapacity(maxResults)
        var indexByMagnet: [String: Int] = [:]
        var failures: [ProviderFailure] = []
        var hadSuccessfulProvider = false

        await withTaskGroup(of: ProviderOutcome?.self) { group in
            for entry in providers {
                group.addTask {
                    let timeout = max(entry.minimumTimeout, tuning.providerTimeoutSeconds)
                    return await outcome(for: entry, query: trimmed, timeout: timeout)
                }
            }

            for await outcome in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                guard let outcome else { continue }
                switch outcome {
                case .success(let name, let items):
                    onProviderResult?(name, nil)
                    hadSuccessfulProvider = true
                    for item in items where searchTitleMatchesQuery(item.title, query: trimmed) {
                        let identity = DownloadsViewModel.canonicalMagnetIdentity(item.magnetLink)
                            ?? item.magnetLink.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if let index = indexByMagnet[identity] {
                            aggregated[index] = aggregated[index].merging(item)
                        } else {
                            indexByMagnet[identity] = aggregated.count
                            aggregated.append(item)
                        }
                    }
                    if !aggregated.isEmpty {
                        onResults?(rankedResults(aggregated, limitResults: limitResults))
                    }
                    // Streaming searches can keep improving the visible,
                    // capped list with results from the remaining websites.
                    if finishWhenFull && aggregated.count >= maxResults {
                        group.cancelAll()
                        break
                    }
                case .failure(let failure):
                    onProviderResult?(failure.name, failure.underlying)
                    failures.append(failure)
                }
            }
        }

        try Task.checkCancellation()
        if !hadSuccessfulProvider && !providers.isEmpty {
            let reasons = failures.map { "• \($0.name): \($0.underlying.localizedDescription)" }
            throw TorrentSearchError.allProvidersFailed(query: trimmed, reasons: reasons)
        }

        return rankedResults(aggregated, limitResults: limitResults)
    }

    private func rankedResults(_ items: [TorrentItem], limitResults: Bool) -> [TorrentItem] {
        let sorted = items.sorted { lhs, rhs in
            if lhs.seeders == rhs.seeders {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.seeders > rhs.seeders
        }

        return limitResults ? Array(sorted.prefix(maxResults)) : sorted
    }
}
