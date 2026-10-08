import Foundation

private enum TrackersBestList {
    /// Bundled fallback used before the first successful refresh and when the
    /// upstream list is temporarily unavailable.
    static let bundledFallback: [String] = [
    "udp://open.demonii.com:1337/announce",
    "udp://zer0day.ch:1337/announce",
    "udp://tracker.publictracker.xyz:6969/announce",
    "http://tracker.opentrackr.org:1337/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://tracker.qu.ax:6969/announce",
    "udp://tracker.peerfect.org:6969/announce",
    "udp://tracker.opentrackr.com:6969/announce",
    "udp://tracker.ilibr.org:6969/announce",
    "udp://tracker.filemail.com:6969/announce",
    "udp://tracker.dler.org:6969/announce",
    "udp://tracker.corpscorp.online:80/announce",
    "udp://tracker.auctor.tv:6969/announce",
    "udp://tracker-udp.gbitt.info:80/announce",
    "udp://torrentclub.online:54123/announce",
    "udp://torrentclub.online:1984/announce",
    "udp://t.overflow.biz:6969/announce",
    "udp://retracker01-msk-virt.corbina.net:80/announce",
    "udp://open.stealth.si:80/announce",
    "udp://mail.segso.net:6969/announce"
    ]
}

/// A small, validated cache for ngosang/trackerslist's `trackers_best` list.
/// The bundled list keeps new installs functional offline; successful refreshes
/// replace it for the native session's adaptive fallback.
final class TrackersBestStore: @unchecked Sendable {
    static let shared = TrackersBestStore()
    static let didUpdateNotification = Notification.Name("Torravia.trackersBestDidUpdate")
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt")!

    private static let cachedListKey = "network.trackersBest.cachedList"
    private static let lastUpdatedKey = "network.trackersBest.lastUpdated"
    private static let refreshInterval: TimeInterval = 24 * 60 * 60
    private static let retryInterval: UInt64 = 60 * 60 * 1_000_000_000
    private static let refreshIntervalNanoseconds: UInt64 = 24 * 60 * 60 * 1_000_000_000

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private var trackers: [String]
    private var managedURLs: Set<String>
    private var lastUpdated: Date?
    private var refreshTask: Task<Void, Never>?

    private init() {
        let cached = Self.validatedTrackers(defaults.string(forKey: Self.cachedListKey) ?? "")
        let initial = cached.isEmpty ? TrackersBestList.bundledFallback : cached
        trackers = initial
        managedURLs = Set((TrackersBestList.bundledFallback + cached).map { $0.lowercased() })
        lastUpdated = defaults.object(forKey: Self.lastUpdatedKey) as? Date
    }

    static var bundledFallback: [String] { TrackersBestList.bundledFallback }

    func current() -> [String] {
        withLock { trackers }
    }

    func isManagedTracker(_ url: String) -> Bool {
        withLock {
            managedURLs.contains(url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    /// Starts one refresh immediately, then keeps the cache fresh daily. A
    /// failed request is retried hourly without disrupting the cached list.
    func startRefreshing() {
        let canStart = withLock { refreshTask == nil }
        guard canStart else {
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.refreshLoop()
        }
        withLock { refreshTask = task }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            let schedule = withLock { () -> (Bool, UInt64) in
                guard let lastUpdated else { return (true, 0) }
                let remaining = Self.refreshInterval - Date().timeIntervalSince(lastUpdated)
                if remaining <= 0 { return (true, 0) }
                return (false, max(1, UInt64(remaining * 1_000_000_000)))
            }

            let delay: UInt64
            if schedule.0 {
                let succeeded = await refreshNow()
                delay = succeeded ? Self.refreshIntervalNanoseconds : Self.retryInterval
            } else {
                delay = schedule.1
            }
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
        }
    }

    @discardableResult
    func refreshNow() async -> Bool {
        var request = URLRequest(url: Self.sourceURL)
        request.timeoutInterval = 20
        request.setValue("Torravia/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let text = String(data: data, encoding: .utf8) else {
                return false
            }
            let refreshed = Self.validatedTrackers(text)
            guard !refreshed.isEmpty else { return false }

            let changed = withLock {
                let changed = trackers != refreshed
                trackers = refreshed
                managedURLs.formUnion(refreshed.map { $0.lowercased() })
                lastUpdated = Date()
                return changed
            }

            defaults.set(refreshed.joined(separator: "\n"), forKey: Self.cachedListKey)
            defaults.set(Date(), forKey: Self.lastUpdatedKey)
            if changed {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.didUpdateNotification,
                        object: nil,
                        userInfo: ["trackers": refreshed]
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    static func validatedTrackers(_ raw: String) -> [String] {
        var seen = Set<String>()
        let values = raw
            .components(separatedBy: .newlines)
            .map { line in
                let withoutComment = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring()
                return withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { value in
                guard !value.isEmpty,
                      let url = URL(string: value),
                      let scheme = url.scheme?.lowercased(),
                      ["udp", "http", "https"].contains(scheme),
                      url.host != nil else { return false }
                // Do not reintroduce the retired endpoint through cached or
                // freshly fetched public tracker lists.
                if scheme == "udp", url.host?.lowercased() == "explodie.org",
                   url.port == 6969 { return false }
                return seen.insert(value.lowercased()).inserted
            }
        return Array(values.prefix(100))
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Compatibility name used by the search-provider implementations.
var defaultMagnetTrackers: [String] { TrackersBestStore.shared.current() }
