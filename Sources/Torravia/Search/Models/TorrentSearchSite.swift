import TorraviaSearchCore
import Foundation

enum TorrentSearchSite: String, CaseIterable, Codable, Hashable, Identifiable {
    case academicTorrents
    nonisolated static let stateDirectoryName = "TorraviaPublic"
    var id: String { rawValue }
    var displayName: String { "Academic Torrents" }
    var description: String { "Datasets shared by the research community." }
    static let defaultOrder: [TorrentSearchSite] = [.academicTorrents]
    static let defaultEnabled: Set<TorrentSearchSite> = [.academicTorrents]
    static let spanishSites: [TorrentSearchSite] = []
    static let extraTrackerURLs: [String] = []
    nonisolated var homepageURL: URL? { URL(string: "https://academictorrents.com/") }
    nonisolated func isHealthSearchEndpoint(_ url: URL, method: String?) -> Bool { url.path.lowercased() == "/database.xml" }
    func namedProvider(session: URLSession, trackers: [String], context: (any ProviderRequestContext)? = nil, isAvailabilityCheck: Bool = false) -> SearchProvider.NamedProvider? {
        SearchProvider.NamedProvider(name: displayName, provider: AcademicTorrentsSearchProvider(session: session, trackers: trackers))
    }
}
