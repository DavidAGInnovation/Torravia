import TorraviaSearchCore
import Combine
import Foundation

enum SearchResultsSortOrder: String, CaseIterable, Identifiable {
    case seeders
    case sizeDescending
    case sizeAscending

    var id: String { rawValue }

    var label: String {
        switch self {
        case .seeders:
            return "Seeders: Most First"
        case .sizeDescending:
            return "Size: Largest First"
        case .sizeAscending:
            return "Size: Smallest First"
        }
    }

    var shortLabel: String {
        switch self {
        case .seeders:
            return "Seeders"
        case .sizeDescending:
            return "Largest"
        case .sizeAscending:
            return "Smallest"
        }
    }

    /// Use the same counts shown in each row, including a valid zero estimate.
    /// Apply the optional display limit after sorting the complete candidate pool.
    func sorted(_ items: [TorrentItem], peerStates: [String: SearchPeerCountState], limit: Int? = nil) -> [TorrentItem] {
        let ranked = items.map { item in
            let state = TrackerPeerScraper.infoHash(in: item.magnetLink)
                .flatMap { peerStates[$0] } ?? SearchPeerCountState()
            return (item: item, seeders: state.seeders ?? -1, leechers: state.leechers ?? -1)
        }
        let sorted = ranked.sorted { lhs, rhs in
            if self != .seeders {
                let descending = self == .sizeDescending
                let unknown = descending ? Int64.min : Int64.max
                let left = lhs.item.sizeBytes > 0 ? lhs.item.sizeBytes : unknown
                let right = rhs.item.sizeBytes > 0 ? rhs.item.sizeBytes : unknown
                if left != right { return descending ? left > right : left < right }
            }
            if lhs.seeders != rhs.seeders { return lhs.seeders > rhs.seeders }
            if lhs.leechers != rhs.leechers { return lhs.leechers > rhs.leechers }
            if self == .seeders, lhs.item.sizeBytes != rhs.item.sizeBytes {
                return lhs.item.sizeBytes > rhs.item.sizeBytes
            }
            let title = lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title)
            if title != .orderedSame { return title == .orderedAscending }
            return lhs.item.magnetLink < rhs.item.magnetLink
        }.map(\.item)
        return limit.map { Array(sorted.prefix(max(0, $0))) } ?? sorted
    }

}

final class SearchPreferencesStore: ObservableObject {
    static let shared = SearchPreferencesStore()

    @Published var enabledSites: Set<TorrentSearchSite> {
        didSet { persistEnabledSites() }
    }
    @Published var sortOrder: SearchResultsSortOrder {
        didSet { persistSortOrder() }
    }

    private let defaults: UserDefaults
    private static let currentSchemaVersion = 1
    private enum Keys {
        static let enabledSites = "public.search.preferences.enabledSites"
        static let sortOrder = "public.search.preferences.sortOrder"
        static let schemaVersion = "public.search.preferences.schemaVersion"
        static let automaticSpanishSite = "public.search.preferences.automaticSpanishSite"
    }

    private static let spanishSites: Set<TorrentSearchSite> = []

    private static let defaultSpanishEnabled: Set<TorrentSearchSite> = []

    private var applyingAutomaticSpanishSelection = false

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        if let stored = defaults.array(forKey: Keys.enabledSites) as? [String] {
            let mappedSet = Set(stored.compactMap(TorrentSearchSite.init(rawValue:)))
            if mappedSet.isEmpty {
                self.enabledSites = TorrentSearchSite.defaultEnabled
            } else {
                let knownSites = Set(TorrentSearchSite.defaultOrder)
                self.enabledSites = mappedSet.intersection(knownSites)
            }
        } else {
            self.enabledSites = TorrentSearchSite.defaultEnabled
        }
        if let storedOrder = defaults.string(forKey: Keys.sortOrder),
           let order = SearchResultsSortOrder(rawValue: storedOrder) {
            self.sortOrder = order
        } else {
            self.sortOrder = .seeders
        }
        applyMigrationsIfNeeded()
    }

    func isEnabled(_ site: TorrentSearchSite) -> Bool {
        enabledSites.contains(site)
    }

    func set(_ site: TorrentSearchSite, enabled: Bool) {
        var updated = enabledSites
        if enabled {
            updated.insert(site)
        } else if updated.count > 1 {
            updated.remove(site)
        }
        if updated != enabledSites {
            if Self.spanishSites.contains(site) && !applyingAutomaticSpanishSelection {
                defaults.removeObject(forKey: Keys.automaticSpanishSite)
            }
            enabledSites = updated
        }
    }

    func enableAllSites() {
        let allSites = Set(TorrentSearchSite.defaultOrder)
        if enabledSites != allSites {
            defaults.removeObject(forKey: Keys.automaticSpanishSite)
            enabledSites = allSites
        }
    }

    func keepOnlyOneSiteEnabled() {
        let retainedSite = TorrentSearchSite.defaultOrder.first(where: enabledSites.contains)
            ?? TorrentSearchSite.defaultOrder.first

        guard let retainedSite else {
            defaults.removeObject(forKey: Keys.automaticSpanishSite)
            enabledSites = TorrentSearchSite.defaultEnabled
            return
        }

        let reducedSites: Set<TorrentSearchSite> = [retainedSite]
        if enabledSites != reducedSites {
            defaults.removeObject(forKey: Keys.automaticSpanishSite)
            enabledSites = reducedSites
        }
    }

    func resetToDefaults() {
        if enabledSites != TorrentSearchSite.defaultEnabled {
            defaults.removeObject(forKey: Keys.automaticSpanishSite)
            enabledSites = TorrentSearchSite.defaultEnabled
        }
    }

    /// Selects the first reachable Spanish provider while preserving an
    /// explicit user selection. The automatic choice is remembered so it can
    /// be refreshed on the next launch if the site's availability changes.
    func selectFirstOnlineSpanishProvider(
        from statuses: [TorrentSearchSite: ProviderHealthState]
    ) {
        let currentSpanish = enabledSites.intersection(Self.spanishSites)
        let previousAutomatic = defaults.string(forKey: Keys.automaticSpanishSite)
            .flatMap(TorrentSearchSite.init(rawValue:))
        let isEligibleForAutomaticUpdate = currentSpanish == Self.defaultSpanishEnabled
            || (previousAutomatic != nil && currentSpanish == [previousAutomatic!])

        guard isEligibleForAutomaticUpdate,
              let firstOnline = Self.orderedSpanishSites.first(where: {
                  if case .online = statuses[$0] { return true }
                  return false
              }) else {
            return
        }

        var updated = enabledSites.subtracting(Self.spanishSites)
        updated.insert(firstOnline)
        applyingAutomaticSpanishSelection = true
        defer { applyingAutomaticSpanishSelection = false }
        if updated != enabledSites {
            enabledSites = updated
        }
        defaults.set(firstOnline.rawValue, forKey: Keys.automaticSpanishSite)
    }

    private static let orderedSpanishSites: [TorrentSearchSite] = []

    var areAllSitesEnabled: Bool {
        enabledSites.count == TorrentSearchSite.defaultOrder.count
    }

    var canReduceToSingleSite: Bool {
        enabledSites.count > 1
    }

    private func applyMigrationsIfNeeded() {
        enabledSites = enabledSites.intersection(Set(TorrentSearchSite.defaultOrder))
        if enabledSites.isEmpty { enabledSites = TorrentSearchSite.defaultEnabled }
        persistEnabledSites()
        defaults.set(Self.currentSchemaVersion, forKey: Keys.schemaVersion)
    }

    private func persistEnabledSites() {
        let identifiers = enabledSites
            .sorted { $0.displayName < $1.displayName }
            .map { $0.rawValue }
        defaults.set(identifiers, forKey: Keys.enabledSites)
    }

    private func persistSortOrder() {
        defaults.set(sortOrder.rawValue, forKey: Keys.sortOrder)
    }
}
