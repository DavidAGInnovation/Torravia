import TorraviaSearchCore
import Combine
import Foundation

enum ProviderHealthState: Equatable, Sendable {
    case unknown
    case checking
    case online
    case offline(String)
    case rateLimited(Date)

    var label: String {
        switch self {
        case .unknown:
            return "Not checked"
        case .checking:
            return "Checking…"
        case .online:
            return "Online"
        case .offline:
            return "Unavailable"
        case .rateLimited:
            return "Rate limited"
        }
    }

    var symbolName: String {
        switch self {
        case .unknown:
            return "questionmark.circle"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .online:
            return "checkmark.circle.fill"
        case .offline:
            return "exclamationmark.triangle.fill"
        case .rateLimited:
            return "clock.fill"
        }
    }

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    var detail: String? {
        if case let .offline(message) = self { return message }
        if case let .rateLimited(date) = self { return "Temporarily rate limited (HTTP 429). Try again after \(date.formatted(date: .omitted, time: .shortened))." }
        return nil
    }
}

@MainActor
final class ProviderHealthStore: ObservableObject {
    static let shared = ProviderHealthStore()

    @Published private(set) var states: [TorrentSearchSite: ProviderHealthState] = [:]
    /// The configured page used to discover or check a provider.
    @Published private(set) var providerLinks: [TorrentSearchSite: URL] = [:]
    /// The live source selected by the provider health check, when available.
    @Published private(set) var sourceLinks: [TorrentSearchSite: URL] = [:]
    /// A directory that actually supplied the selected search endpoint.
    @Published private(set) var proxyDirectoryLinks: [TorrentSearchSite: URL] = [:]
    /// Compatibility view of the currently usable link.
    @Published private(set) var links: [TorrentSearchSite: URL] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?

    private var checkTask: Task<Void, Never>?
    private var searchObservationVersions: [TorrentSearchSite: Int] = [:]
    private var searchObservationVersion = 0

    init() {
        providerLinks = Self.defaultLinks()
        links = providerLinks
    }

    func status(for site: TorrentSearchSite) -> ProviderHealthState {
        states[site] ?? .unknown
    }

    func link(for site: TorrentSearchSite) -> URL? {
        sourceLinks[site] ?? providerLinks[site]
    }

    func providerLink(for site: TorrentSearchSite) -> URL? {
        providerLinks[site]
    }

    func sourceLink(for site: TorrentSearchSite) -> URL? {
        sourceLinks[site]
    }

    func proxyDirectoryLink(for site: TorrentSearchSite) -> URL? {
        proxyDirectoryLinks[site]
    }

    /// A completed search is stronger evidence than an earlier availability
    /// probe. Keep Settings in sync even when only one provider fails.
    func recordSearchOutcome(providerName: String, error: Error?) {
        guard let site = TorrentSearchSite.defaultOrder.first(where: { $0.displayName == providerName }) else { return }
        searchObservationVersion += 1
        searchObservationVersions[site] = searchObservationVersion
        states[site] = error.map { Self.failureState(for: $0) } ?? .online
    }

    func checkAll() {
        checkTask?.cancel()

        let sites = TorrentSearchSite.defaultOrder
        states = Dictionary(uniqueKeysWithValues: sites.map { ($0, ProviderHealthState.checking) })
        let fallbackLinks = Self.defaultLinks()
        providerLinks = fallbackLinks
        sourceLinks = [:]
        proxyDirectoryLinks = [:]
        links = fallbackLinks
        isChecking = true
        lastCheckedAt = nil

        let configuration = SearchProvider.sessionConfiguration(mode: .balanced)
        let session = URLSession(configuration: configuration)

        let observationVersionsAtStart = searchObservationVersions
        checkTask = Task { [weak self] in
            let results = await Self.checkSites(sites, session: session)
            session.invalidateAndCancel()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            for (site, result) in results where self.searchObservationVersions[site] == observationVersionsAtStart[site] {
                self.states[site] = result.state
            }
            let resolvedLinks = results.reduce(into: [TorrentSearchSite: URL]()) { links, entry in
                if let url = entry.value.url {
                    links[entry.key] = Self.canonicalBaseURL(url)
                }
            }
            self.providerLinks = fallbackLinks
            self.sourceLinks = resolvedLinks
            self.proxyDirectoryLinks = results.reduce(into: [:]) { links, entry in
                if let url = entry.value.proxyDirectoryURL { links[entry.key] = url }
            }
            self.links = resolvedLinks.reduce(into: fallbackLinks) { links, entry in
                links[entry.key] = entry.value
            }
            self.isChecking = false
            self.lastCheckedAt = Date()
            SearchPreferencesStore.shared.selectFirstOnlineSpanishProvider(from: self.states)
        }
    }

    deinit {
        checkTask?.cancel()
    }

    private static func defaultLinks() -> [TorrentSearchSite: URL] {
        Dictionary(uniqueKeysWithValues: TorrentSearchSite.defaultOrder.compactMap { site in
            guard let url = defaultLink(for: site) else { return nil }
            return (site, canonicalBaseURL(url))
        })
    }

    private static func canonicalBaseURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    private static func defaultLink(for site: TorrentSearchSite) -> URL? { site.homepageURL }

    private static func checkSites(
        _ sites: [TorrentSearchSite],
        session: URLSession
    ) async -> [TorrentSearchSite: ProviderHealthResult] {
        await withTaskGroup(of: ProviderHealthResult.self) { group in
            for site in sites {
                group.addTask {
                    let result = await checkSiteLinks(site, session: session)
                    return ProviderHealthResult(site: site, state: result.state, url: result.url, proxyDirectoryURL: result.proxyDirectoryURL)
                }
            }

            var results: [TorrentSearchSite: ProviderHealthResult] = [:]
            for await result in group {
                results[result.site] = result
            }
            return results
        }
    }

    static func checkSite(
        _ site: TorrentSearchSite,
        session: URLSession,
        context: (any ProviderRequestContext)? = nil
    ) async -> (ProviderHealthState, URL?) {
        let result = await checkSiteLinks(site, session: session, context: context)
        return (result.state, result.url)
    }

    static func checkSiteLinks(
        _ site: TorrentSearchSite,
        session: URLSession,
        context: (any ProviderRequestContext)? = nil
    ) async -> (state: ProviderHealthState, url: URL?, proxyDirectoryURL: URL?) {
        let observer = ProviderSearchEndpointObserver(site: site)
        // Give each provider its own observer and cookie session so concurrent
        // mirror lookups cannot mix up the resolved source URLs.
        let probeSession = URLSession(configuration: session.configuration)
        ProviderSearchProbeRegistry.register(session: probeSession) { request, data, response in
            observer.record(request: request, data: data, response: response)
        }
        defer {
            ProviderSearchProbeRegistry.unregister(session: probeSession)
            probeSession.invalidateAndCancel()
        }
        do {
            try await SearchProvider.checkAvailability(for: site, session: probeSession, context: context)
            guard let url = observer.successfulSearchURL else {
                if let failure = observer.searchFailure { throw failure }
                throw HealthCheckError.invalidSearchResponse
            }
            return (.online, url, ProviderSearchProbeRegistry.proxyDirectory(session: probeSession, for: url))
        } catch is CancellationError {
            return (.offline("Check canceled"), nil, nil)
        } catch {
            return (failureState(for: error), nil, nil)
        }
    }

    private static func failureState(for error: Error) -> ProviderHealthState {
        if let limit = error as? any SearchRateLimitError { return .rateLimited(limit.retryAt) }
        return .offline(message(for: error))
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let error as HTTPStatusError:
            return "HTTP \(error.statusCode) — search unavailable"
        case HealthCheckError.invalidSearchResponse:
            return "Search endpoint did not return a successful response"
        default:
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                return nsError.localizedDescription
            }
            return error.localizedDescription
        }
    }
}

private enum HealthCheckError: Error {
    case invalidSearchResponse
}

private struct ProviderHealthResult: Sendable {
    let site: TorrentSearchSite
    let state: ProviderHealthState
    let url: URL?
    let proxyDirectoryURL: URL?
}

/// Capture only search/feed responses. A reachable mirror directory or
/// homepage must never turn a failed or redirected search into “Online”.
nonisolated private final class ProviderSearchEndpointObserver: @unchecked Sendable {
    private let site: TorrentSearchSite
    private let lock = NSLock()
    private var resolvedSearchURL: URL?
    private var failedSearch: HTTPStatusError?

    init(site: TorrentSearchSite) { self.site = site }

    var successfulSearchURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedSearchURL
    }

    var searchFailure: HTTPStatusError? {
        lock.lock()
        defer { lock.unlock() }
        return failedSearch
    }

    func record(request: URLRequest, data: Data, response: URLResponse) {
        guard let requestURL = request.url, isSearchEndpoint(requestURL, method: request.httpMethod),
              let response = response as? HTTPURLResponse else { return }
        lock.lock()
        defer { lock.unlock() }
        if (200..<300).contains(response.statusCode), !data.isEmpty, let url = response.url,
           isSearchEndpoint(url, method: request.httpMethod) {
            resolvedSearchURL = url
        } else if !(200..<300).contains(response.statusCode) {
            failedSearch = HTTPStatusError(url: requestURL, statusCode: response.statusCode)
        }
    }

    private func isSearchEndpoint(_ url: URL, method: String?) -> Bool {
        site.isHealthSearchEndpoint(url, method: method)
    }

}
