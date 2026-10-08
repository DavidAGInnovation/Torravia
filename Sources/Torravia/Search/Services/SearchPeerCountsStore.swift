import TorraviaSearchCore
import Combine
import Foundation
import Network

nonisolated struct TrackerPeerEstimate: Equatable, Sendable {
    let seeders: Int
    let leechers: Int
    let checkedAt: Date
    let tracker: URL
}

struct SearchPeerCountState: Equatable {
    var estimate: TrackerPeerEstimate?
    var isChecking = false
    var checkedAt: Date?
    var unavailableReason: UnavailableReason?

    enum UnavailableReason: Equatable {
        case networkPolicy, unsupportedMagnet, noApprovedTrackers, noResponse

        var detail: String {
            switch self {
            case .networkPolicy: return "Tracker checks paused by network privacy settings"
            case .unsupportedMagnet: return "Tracker counts unavailable for this magnet format"
            case .noApprovedTrackers: return "No supported public tracker in this magnet"
            case .noResponse: return "Public trackers did not return a scrape estimate"
            }
        }
    }

    var seeders: Int? { estimate?.seeders }

    var leechers: Int? { estimate?.leechers }

    func seedersLabel(for item: TorrentItem) -> String {
        seeders.map { "\($0) tracker seeders" } ?? "Unknown tracker seeders"
    }

    func leechersLabel(for item: TorrentItem) -> String {
        leechers.map { "\($0) tracker leechers" } ?? "Unknown tracker leechers"
    }

    var detail: String? {
        if let estimate {
            return "Tracker estimate · checked \(estimate.checkedAt.formatted(date: .omitted, time: .shortened))"
        }
        if isChecking { return "Checking tracker estimate…" }
        if let unavailableReason { return unavailableReason.detail }
        return "Tracker estimate unknown"
    }
}

/// Check every result before the search publishes it, with bounded concurrency
/// and short timeouts. No torrent is added or announced.
@MainActor
final class SearchPeerCountsStore: ObservableObject {
    typealias Lookup = @Sendable (String) async -> TrackerPeerEstimate?
    @Published private(set) var states: [String: SearchPeerCountState] = [:]
    private var batchTask: Task<Void, Never>?
    private var generation = UUID()
    private let lookup: Lookup?
    private let concurrency: Int
    private let approvedTrackers: [String]?
    @Published private var checksPaused = false
    private var checkedTrackers: [String: [URL]] = [:]

    init(concurrency: Int = 3, lookup: Lookup? = nil, approvedTrackers: [String]? = nil) {
        self.concurrency = max(concurrency, 1)
        self.lookup = lookup
        self.approvedTrackers = approvedTrackers
    }

    static func checksAllowed(proxyType: TorrentProxyType, interface: String,
                              anonymous: Bool, blockedRanges: String) -> Bool {
        // Direct probes cannot implement the native engine's proxy/interface
        // and IP filtering policies. Counts remain unknown under those policies.
        proxyType == .none && !anonymous && blockedRanges.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ["", "auto", "all"].contains(interface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    func state(for item: TorrentItem) -> SearchPeerCountState {
        if checksPaused { return SearchPeerCountState(unavailableReason: .networkPolicy) }
        guard let hash = TrackerPeerScraper.infoHash(in: item.magnetLink) else {
            return SearchPeerCountState(unavailableReason: .unsupportedMagnet)
        }
        return states[hash] ?? SearchPeerCountState()
    }

    func checkAll(_ items: [TorrentItem], allowed: Bool) async {
        cancel()
        checksPaused = !allowed
        guard allowed, !Task.isCancelled else {
            states = [:]
            return
        }
        let id = generation
        let approved = approvedTrackers ?? TrackerPeerScraper.approvedPublicTrackers
        let lookup = self.lookup
        var seen = Set<String>()
        let pending = items.compactMap { item -> (String, String)? in
            guard let hash = TrackerPeerScraper.infoHash(in: item.magnetLink), seen.insert(hash).inserted else { return nil }
            let trackers = TrackerPeerScraper.trackers(in: item.magnetLink, fallback: approved)
            if let state = states[hash], let date = state.checkedAt,
               Date().timeIntervalSince(date) < (state.estimate == nil ? 30 : 300),
               state.estimate != nil || checkedTrackers[hash] == trackers { return nil }
            checkedTrackers[hash] = trackers
            if lookup == nil, trackers.isEmpty {
                states[hash] = SearchPeerCountState(checkedAt: Date(), unavailableReason: .noApprovedTrackers)
                return nil
            }
            states[hash] = SearchPeerCountState(isChecking: true)
            return (hash, item.magnetLink)
        }
        let concurrency = self.concurrency
        let task = Task { @MainActor [weak self] in
            if lookup == nil {
                let estimates = await TrackerPeerScraper.checkMany(magnets: pending.map { $0.1 }, fallback: approved)
                guard let self, !Task.isCancelled, self.generation == id else { return }
                let checkedAt = Date()
                for (hash, _) in pending {
                    self.states[hash] = SearchPeerCountState(estimate: estimates[hash], checkedAt: checkedAt,
                        unavailableReason: estimates[hash] == nil ? .noResponse : nil)
                }
                return
            }
            guard let lookup else { return }
            await withTaskGroup(of: (String, TrackerPeerEstimate?).self) { group in
                var iterator = pending.makeIterator()
                for _ in 0..<concurrency {
                    guard let (hash, magnet) = iterator.next() else { break }
                    group.addTask { (hash, await lookup(magnet)) }
                }
                for await (hash, estimate) in group {
                    guard let self, !Task.isCancelled, self.generation == id else {
                        group.cancelAll()
                        return
                    }
                    self.states[hash] = SearchPeerCountState(estimate: estimate, checkedAt: Date(),
                        unavailableReason: estimate == nil ? .noResponse : nil)
                    if let (nextHash, magnet) = iterator.next() {
                        group.addTask { (nextHash, await lookup(magnet)) }
                    }
                }
            }
        }
        batchTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == id {
            batchTask = nil
            if Task.isCancelled { cancel() }
        }
    }

    func cancel() {
        generation = UUID()
        batchTask?.cancel()
        batchTask = nil
        // Successful estimates remain cached; abandoned checks may be retried.
        for hash in states.keys where states[hash]?.isChecking == true { states[hash] = nil }
    }

}

/// Implements scrape, rather than announce, so checking a result never joins
/// its swarm. Counts from different trackers are not added (peers can overlap).
nonisolated enum TrackerPeerScraper {
    // OpenTrackr documents this UDP address on its own site. Keep it
    // approved when trackers_best lists its HTTP address instead.
    static let openTrackrUDP = "udp://tracker.opentrackr.org:1337/announce"

    @MainActor static var approvedPublicTrackers: [String] {
        TrackersBestStore.shared.current() + TorrentSearchSite.extraTrackerURLs + [openTrackrUDP]
    }

    struct Request: Equatable, Sendable {
        let tracker: URL
        let hashes: [String]
    }
    typealias Scrape = @Sendable (URL, [Data]) async -> [TrackerPeerEstimate?]

    /// 64 hashes keep UDP packets below a typical network MTU. HTTP trackers
    /// retain single-hash requests for compatibility, with bounded concurrency.
    nonisolated static func requests(magnets: [String], fallback: [String]) -> [Request] {
        var hashesByTracker: [URL: [String]] = [:]
        for magnet in magnets {
            guard let hash = infoHash(in: magnet) else { continue }
            for tracker in trackers(in: magnet, fallback: fallback) {
                if !(hashesByTracker[tracker] ?? []).contains(hash) {
                    hashesByTracker[tracker, default: []].append(hash)
                }
            }
        }
        return hashesByTracker.keys.sorted { $0.absoluteString < $1.absoluteString }.flatMap { tracker in
            let hashes = hashesByTracker[tracker]!
            let batchSize = tracker.scheme?.lowercased() == "udp" ? 64 : 1
            return stride(from: 0, to: hashes.count, by: batchSize).map { offset in
                Request(tracker: tracker, hashes: Array(hashes[offset..<min(offset + batchSize, hashes.count)]))
            }
        }
    }

    nonisolated static func checkMany(magnets: [String], fallback: [String]? = nil,
                                     concurrency: Int = 6,
                                     scrape: @escaping Scrape = { tracker, hashes in
        if tracker.scheme?.lowercased() == "udp" {
            return await UDPTrackerScrape.check(tracker: tracker, hashes: hashes)
        }
        return [await httpCheck(tracker: tracker, hash: hashes[0])]
    }) async -> [String: TrackerPeerEstimate] {
        guard !Task.isCancelled, !magnets.isEmpty else { return [:] }
        let approvedTrackers: [String]
        if let fallback { approvedTrackers = fallback }
        else { approvedTrackers = await MainActor.run { approvedPublicTrackers } }
        let requests = requests(magnets: magnets, fallback: approvedTrackers)
        return await withTaskGroup(of: (Request, [TrackerPeerEstimate?]).self) { group in
            var iterator = requests.makeIterator()
            for _ in 0..<max(concurrency, 1) {
                guard let request = iterator.next() else { break }
                group.addTask { (request, await scrape(request.tracker, request.hashes.compactMap(hashBytes))) }
            }
            var best: [String: TrackerPeerEstimate] = [:]
            for await (request, estimates) in group {
                guard !Task.isCancelled else { group.cancelAll(); return [:] }
                if estimates.count == request.hashes.count {
                    for (hash, estimate) in zip(request.hashes, estimates) {
                        if let estimate, best[hash] == nil || estimate.seeders > best[hash]!.seeders {
                            best[hash] = estimate
                        }
                    }
                }
                if let request = iterator.next() {
                    group.addTask { (request, await scrape(request.tracker, request.hashes.compactMap(hashBytes))) }
                }
            }
            return best
        }
    }

    nonisolated static func infoHash(in magnet: String) -> String? {
        guard let parts = MagnetLink.components(magnet),
              let xt = parts.queryItems?.first(where: { $0.name.lowercased() == "xt" && $0.value?.lowercased().hasPrefix("urn:btih:") == true })?.value,
              let bytes = hashBytes(String(xt.dropFirst(9))) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func hashBytes(_ value: String) -> Data? {
        if value.count == 40 {
            let chars = Array(value)
            var data = Data()
            for index in stride(from: 0, to: 40, by: 2) {
                guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
                data.append(byte)
            }
            return data
        }
        guard value.count == 32 else { return nil }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt32 = 0
        var bits = 0
        var data = Data()
        for char in value.uppercased() {
            guard let digit = alphabet.firstIndex(of: char) else { return nil }
            buffer = (buffer << 5) | UInt32(digit)
            bits += 5
            if bits >= 8 {
                bits -= 8
                data.append(UInt8((buffer >> bits) & 255))
            }
        }
        return data.count == 20 ? data : nil
    }

    nonisolated static func trackers(in magnet: String, fallback: [String] = []) -> [URL] {
        guard let parts = MagnetLink.components(magnet) else { return [] }
        let advertised = parts.queryItems?.filter { $0.name.lowercased() == "tr" }.compactMap(\.value) ?? []
        // Probe only the app's maintained public trackers, never arbitrary
        // endpoints supplied in a result (which may include private trackers).
        let approved = Set(fallback.compactMap(URL.init(string:)).compactMap(trackerEndpoint))
        let candidates = advertised.isEmpty ? fallback : advertised.filter {
            guard let url = URL(string: $0), let endpoint = trackerEndpoint(url) else { return false }
            return approved.contains(endpoint)
        }
        var hosts = Set<String>()
        return candidates.compactMap(URL.init(string:)).filter { url in
            guard ["udp", "http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
            return hosts.insert(host.lowercased()).inserted
        }.prefix(3).map { $0 }
    }

    /// UDP scrapes use the host and port. Some providers omit the conventional
    /// /announce suffix; accept those aliases of maintained public endpoints.
    /// Keep other paths and tokens distinct so private URLs are not approved.
    nonisolated private static func trackerEndpoint(_ url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["udp", "http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if scheme == "udp", parts.path.isEmpty || parts.path == "/" {
            parts.path = "/announce"
        }
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) {
            parts.port = nil
        }
        return parts.string
    }

    nonisolated static func check(magnet: String) async -> TrackerPeerEstimate? {
        guard let hash = infoHash(in: magnet) else { return nil }
        return await checkMany(magnets: [magnet])[hash]
    }

    nonisolated static func scrapeURL(tracker: URL, hash: Data) -> URL? {
        guard hash.count == 20, var parts = URLComponents(url: tracker, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let last = parts.path.split(separator: "/").last, last.hasPrefix("announce") else { return nil }
        parts.path = String(parts.path.dropLast(last.count)) + "scrape" + last.dropFirst(8)
        let encoded = hash.map { String(format: "%%%02X", $0) }.joined()
        parts.percentEncodedQuery = (parts.percentEncodedQuery.map { $0 + "&" } ?? "") + "info_hash=" + encoded
        return parts.url
    }

    nonisolated private static func httpCheck(tracker: URL, hash: Data) async -> TrackerPeerEstimate? {
        guard let url = scrapeURL(tracker: tracker, hash: hash) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config, delegate: ScrapeSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: url)
            guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200,
                  let counts = parseHTTPResponse(data, hash: hash) else { return nil }
            return TrackerPeerEstimate(seeders: counts.0, leechers: counts.1, checkedAt: Date(), tracker: tracker)
        } catch { return nil }
    }

    nonisolated static func parseHTTPResponse(_ data: Data, hash: Data) -> (Int, Int)? {
        guard data.count <= 65_536 else { return nil }
        var parser = ScrapeBencodeParser(data: Array(data))
        guard let node = parser.parse(), parser.index == data.count,
              case let .dictionary(root) = node, root[Data("failure reason".utf8)] == nil,
              case let .dictionary(files)? = root[Data("files".utf8)],
              case let .dictionary(entry)? = files[hash],
              case let .integer(seeds)? = entry[Data("complete".utf8)],
              case let .integer(leechers)? = entry[Data("incomplete".utf8)],
              seeds >= 0, leechers >= 0 else { return nil }
        return (seeds, leechers)
    }
}

/// A scrape must stay on the approved endpoint; do not follow tracker redirects.
nonisolated private final class ScrapeSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Preserve binary dictionary keys: info hashes are not UTF-8 strings.
nonisolated private struct ScrapeBencodeParser {
    indirect enum Node { case integer(Int), string(Data), dictionary([Data: Node]), list([Node]) }
    let data: [UInt8]
    var index = 0
    nonisolated mutating func parse(depth: Int = 0) -> Node? {
        guard index < data.count, depth < 8 else { return nil }
        let byte = data[index]
        if byte == 105 {
            index += 1
            let start = index
            while index < data.count && data[index] != 101 { index += 1 }
            guard index < data.count, let value = Int(String(decoding: data[start..<index], as: UTF8.self)),
                  String(value) == String(decoding: data[start..<index], as: UTF8.self) else { return nil }
            index += 1
            return .integer(value)
        }
        if byte == 100 || byte == 108 {
            index += 1
            var dictionary: [Data: Node] = [:]
            var list: [Node] = []
            while index < data.count && data[index] != 101 {
                if byte == 100 {
                    guard case let .string(key)? = parse(depth: depth + 1), let value = parse(depth: depth + 1), dictionary[key] == nil else { return nil }
                    dictionary[key] = value
                } else {
                    guard let value = parse(depth: depth + 1) else { return nil }
                    list.append(value)
                }
            }
            guard index < data.count else { return nil }
            index += 1
            return byte == 100 ? .dictionary(dictionary) : .list(list)
        }
        let start = index
        while index < data.count && (48...57).contains(data[index]) { index += 1 }
        guard index < data.count, data[index] == 58, index > start,
              let length = Int(String(decoding: data[start..<index], as: UTF8.self)), length >= 0,
              length <= data.count - index - 1 else { return nil }
        index += 1
        let value = Data(data[index..<index + length])
        index += length
        return .string(value)
    }
}

nonisolated final class UDPTrackerScrape: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Torravia.trackerScrape")
    private let connection: NWConnection
    private let tracker: URL
    private let hashes: [Data]
    private var continuation: CheckedContinuation<[TrackerPeerEstimate?], Never>?
    private var finished = false
    private var transaction = UInt32.random(in: 0...UInt32.max)
    private var isScraping = false

    nonisolated private init(tracker: URL, hashes: [Data], port: NWEndpoint.Port) {
        self.tracker = tracker
        self.hashes = hashes
        connection = NWConnection(host: NWEndpoint.Host(tracker.host!), port: port, using: .udp)
    }

    nonisolated static func check(tracker: URL, hash: Data) async -> TrackerPeerEstimate? {
        let estimates = await check(tracker: tracker, hashes: [hash])
        return estimates.first ?? nil
    }

    nonisolated static func check(tracker: URL, hashes: [Data]) async -> [TrackerPeerEstimate?] {
        guard (1...64).contains(hashes.count), hashes.allSatisfy({ $0.count == 20 }),
              let rawPort = tracker.port, let port = NWEndpoint.Port(rawValue: UInt16(clamping: rawPort)),
              rawPort > 0, rawPort <= 65535 else { return [] }
        let operation = UDPTrackerScrape(tracker: tracker, hashes: hashes, port: port)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.queue.async { operation.start(continuation) }
            }
        } onCancel: { operation.queue.async { operation.finish([]) } }
    }

    nonisolated private func start(_ continuation: CheckedContinuation<[TrackerPeerEstimate?], Never>) {
        guard !finished else { continuation.resume(returning: []); return }
        self.continuation = continuation
        queue.asyncAfter(deadline: .now() + 3) { self.finish([]) }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                var request = Data()
                request.appendInteger(UInt64(0x41727101980))
                request.appendInteger(UInt32(0))
                request.appendInteger(self.transaction)
                self.send(request)
            case .failed, .cancelled: self.finish([])
            default: break
            }
        }
        connection.start(queue: queue)
    }

    nonisolated private func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.finished else { return }
            if error != nil { self.finish([]) } else { self.receive() }
        })
    }

    nonisolated private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.finished else { return }
            guard error == nil, let data, data.count >= 8 else { self.finish([]); return }
            guard data.integer(at: 4) == self.transaction else { self.receive(); return }
            if !self.isScraping {
                guard data.integer(at: 0) == 0, data.count >= 16 else { self.finish([]); return }
                self.isScraping = true
                self.transaction = UInt32.random(in: 0...UInt32.max)
                var request = Data(data[8..<16])
                request.appendInteger(UInt32(2))
                request.appendInteger(self.transaction)
                self.hashes.forEach { request.append($0) }
                self.send(request)
            } else {
                guard let counts = Self.parseResponses(data, transaction: self.transaction, count: self.hashes.count) else {
                    self.finish([])
                    return
                }
                let checkedAt = Date()
                self.finish(counts.map { TrackerPeerEstimate(seeders: $0.0, leechers: $0.1,
                    checkedAt: checkedAt, tracker: self.tracker) })
            }
        }
    }

    nonisolated static func parseResponse(_ data: Data, transaction: UInt32) -> (Int, Int)? {
        parseResponses(data, transaction: transaction, count: 1)?.first
    }

    nonisolated static func parseResponses(_ data: Data, transaction: UInt32, count: Int) -> [(Int, Int)]? {
        guard (1...64).contains(count), data.count == 8 + 12 * count,
              data.integer(at: 0) == 2, data.integer(at: 4) == transaction else { return nil }
        return (0..<count).map { n in
            (Int(data.integer(at: 8 + 12 * n)), Int(data.integer(at: 16 + 12 * n)))
        }
    }

    nonisolated private func finish(_ result: [TrackerPeerEstimate?]) {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private extension Data {
    nonisolated mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
    nonisolated func integer(at offset: Int) -> UInt32 {
        self[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
