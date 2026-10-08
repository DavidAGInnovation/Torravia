import TorraviaSearchCore
//
//  DownloadModel.swift
//  Torravia
//
//  Download value types and persistence records kept separate from runtime
//  orchestration and transport code.
//

import Foundation

extension DownloadsViewModel {
    // MARK: - Nested Types
    struct Download: Identifiable, Hashable {
        struct FileEntry: Hashable {
            let relativePath: String
            let length: Int64
            var isPadding = false
        }
        enum Status: String, Equatable, Codable {
            case queued
            case downloading
            case paused
            case completed
            case failed
        }
        enum ShareRatioAction: String, CaseIterable, Codable, Identifiable {
            case none
            case pause
            case remove

            var id: String { rawValue }
            var title: String {
                switch self {
                case .none: return "Keep seeding"
                case .pause: return "Pause torrent"
                case .remove: return "Remove torrent"
                }
            }
        }
        let id: UUID
        var torrent: TorrentItem
        var metadataTitle: String?
        var progress: Double
        var status: Status
        var speedBytesPerSec: Int64
        var uploadSpeedBytesPerSec: Int64
        var averageSpeedBytesPerSec: Int64
        var peakSpeedBytesPerSec: Int64
        var etaSeconds: Int?
        var completedAt: Date?
        var destinationURL: URL?
        var storageURL: URL?
        /// Final parent directory for downloads without an app-created wrapper.
        var contentRootURL: URL?
        var storageBookmark: Data?
        var flattenedTargetURL: URL?
        var totalBytes: Int64?
        var downloadedBytes: Int64
        var uploadedBytes: Int64
        var numPeers: Int
        var connectablePeers: Int
        var connectedSeeders: Int
        var connectedLeechers: Int
        /// Raw libtorrent `list_peers` count: peers currently retained in the
        /// engine's peer list, before connection/cached/swarm estimates.
        var knownPeerCount: Int
        var knownSeeders: Int
        var knownLeechers: Int
        var swarmSeeders: Int?
        var swarmLeechers: Int?
        /// Libtorrent's engine-wide swarm fields (num_complete and
        /// num_incomplete), when a tracker or DHT source reports them.
        var engineSwarmSeeders: Int?
        var engineSwarmLeechers: Int?
        var isRestoringProgress = false
        var announcePeerEstimate: Int?
        var errorMessage: String?
        var infoHash: String?
        var files: [FileEntry]
        var torrentData: Data?
        var torrentFileName: String?
        /// User-owned originals: verify and upload only; never download or delete their content.
        var isSeedOnly = false
        var isSeeding: Bool
        var isSeedingDesired: Bool
        var seedingSince: Date?
        var startedAt: Date?
        var hasAnnouncedCompletion: Bool
        var queuePriority: Int
        var isForceStarted: Bool
        var isSequentialDownload: Bool
        var selectedFileIndices: Set<Int>?
        var filePriorities: [Int]?
        var firstLastPiecePriority: Bool
        var downloadLimitBytesPerSec: Int64
        var uploadLimitBytesPerSec: Int64
        var maxUploads: Int
        var category: String
        var tags: [String]
        var shareRatioLimit: Double?
        var shareRatioAction: ShareRatioAction
        var seedingTimeLimitMinutes: Int?
        var inactiveSeedingTimeLimitMinutes: Int?
        var seedingTimeSeconds: Int64 = 0
        var inactiveSeedingTimeSeconds: Int64 = 0

        init(id: UUID = UUID(),
             torrent: TorrentItem,
             progress: Double = 0,
             status: Status = .queued,
             speedBytesPerSec: Int64 = 0,
             uploadSpeedBytesPerSec: Int64 = 0,
             averageSpeedBytesPerSec: Int64 = 0,
             peakSpeedBytesPerSec: Int64 = 0,
             etaSeconds: Int? = nil,
             completedAt: Date? = nil,
             destinationURL: URL? = nil,
             storageURL: URL? = nil,
             storageBookmark: Data? = nil,
             flattenedTargetURL: URL? = nil,
             totalBytes: Int64? = nil,
             downloadedBytes: Int64 = 0,
             uploadedBytes: Int64 = 0,
             numPeers: Int = 0,
             connectablePeers: Int = 0,
             connectedSeeders: Int = 0,
             connectedLeechers: Int = 0,
             knownPeerCount: Int? = nil,
             knownSeeders: Int = 0,
             knownLeechers: Int = 0,
             swarmSeeders: Int? = nil,
             swarmLeechers: Int? = nil,
             engineSwarmSeeders: Int? = nil,
             engineSwarmLeechers: Int? = nil,
             announcePeerEstimate: Int? = nil,
             errorMessage: String? = nil,
             infoHash: String? = nil,
             files: [FileEntry] = [],
             torrentData: Data? = nil,
             torrentFileName: String? = nil,
             isSeeding: Bool = false,
             seedingSince: Date? = nil,
             startedAt: Date? = nil,
             hasAnnouncedCompletion: Bool = false,
             queuePriority: Int = 0,
             isForceStarted: Bool = false,
             isSequentialDownload: Bool = false,
             selectedFileIndices: Set<Int>? = nil,
             filePriorities: [Int]? = nil,
             firstLastPiecePriority: Bool = false,
             downloadLimitBytesPerSec: Int64 = 0,
             uploadLimitBytesPerSec: Int64 = 0,
             maxUploads: Int = 4,
             category: String = "",
             tags: [String] = [],
             shareRatioLimit: Double? = nil,
             shareRatioAction: ShareRatioAction = .none,
             seedingTimeLimitMinutes: Int? = nil,
             inactiveSeedingTimeLimitMinutes: Int? = nil) {
            self.id = id
            self.torrent = torrent
            self.progress = progress
            self.status = status
            self.speedBytesPerSec = speedBytesPerSec
            self.uploadSpeedBytesPerSec = uploadSpeedBytesPerSec
            self.averageSpeedBytesPerSec = averageSpeedBytesPerSec
            self.peakSpeedBytesPerSec = max(peakSpeedBytesPerSec, averageSpeedBytesPerSec)
            self.etaSeconds = etaSeconds
            self.completedAt = completedAt
            self.destinationURL = destinationURL
            self.storageURL = storageURL
            self.storageBookmark = storageBookmark
            self.flattenedTargetURL = flattenedTargetURL
            self.totalBytes = totalBytes
            self.downloadedBytes = downloadedBytes
            self.uploadedBytes = uploadedBytes
            self.numPeers = numPeers
            self.connectablePeers = max(connectablePeers, 0)
            self.connectedSeeders = connectedSeeders
            self.connectedLeechers = connectedLeechers
            self.knownPeerCount = max(knownPeerCount ?? max(knownSeeders + knownLeechers, numPeers), 0)
            self.knownSeeders = max(knownSeeders, connectedSeeders)
            self.knownLeechers = max(knownLeechers, connectedLeechers)
            self.swarmSeeders = swarmSeeders
            self.swarmLeechers = swarmLeechers
            self.engineSwarmSeeders = engineSwarmSeeders
            self.engineSwarmLeechers = engineSwarmLeechers
            self.announcePeerEstimate = announcePeerEstimate
            self.errorMessage = errorMessage
            self.infoHash = infoHash
            self.files = files
            self.torrentData = torrentData
            if let explicitName = torrentFileName, !explicitName.isEmpty {
                self.torrentFileName = explicitName
            } else if let sourceName = torrent.sourceURL?.lastPathComponent {
                self.torrentFileName = sourceName
            } else {
                self.torrentFileName = nil
            }
            self.isSeeding = isSeeding
            self.isSeedingDesired = isSeeding
            self.seedingSince = seedingSince
            self.startedAt = startedAt
            self.hasAnnouncedCompletion = hasAnnouncedCompletion
            self.queuePriority = queuePriority
            self.isForceStarted = isForceStarted
            self.isSequentialDownload = isSequentialDownload
            self.selectedFileIndices = selectedFileIndices
            self.filePriorities = filePriorities
            self.firstLastPiecePriority = firstLastPiecePriority
            self.downloadLimitBytesPerSec = max(downloadLimitBytesPerSec, 0)
            self.uploadLimitBytesPerSec = max(uploadLimitBytesPerSec, 0)
            self.maxUploads = max(maxUploads, 0)
            self.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
            self.tags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })).sorted()
            self.shareRatioLimit = shareRatioLimit.flatMap { $0 > 0 ? $0 : nil }
            self.shareRatioAction = shareRatioAction
            self.seedingTimeLimitMinutes = seedingTimeLimitMinutes.flatMap { $0 > 0 ? min($0, 5_256_000) : nil }
            self.inactiveSeedingTimeLimitMinutes = inactiveSeedingTimeLimitMinutes.flatMap { $0 > 0 ? min($0, 5_256_000) : nil }
        }

        var title: String { DownloadsViewModel.resolvedTorrentTitle(currentTitle: torrent.title, metadataTitle: metadataTitle ?? "") }
        var originalSearchTitle: String? { title != torrent.title ? torrent.title : nil }
        var magnetLink: String { torrent.magnetLink }
        var resolvedSizeBytes: Int64 { totalBytes ?? torrent.sizeBytes }
        var hasResolvedSize: Bool { resolvedSizeBytes > 0 }

        /// Peers retained in this session's local peer cache. This is not a
        /// swarm-wide count and may include peers that are currently
        /// unavailable or have already failed a connection attempt.
        var cachedPeerCount: Int {
            max(knownSeeders + knownLeechers, numPeers)
        }

        /// The latest tracker scrape estimate, when both scrape values are
        /// available. This is independent from the local peer cache.
        var trackerScrapePeerEstimate: Int? {
            guard let swarmSeeders, let swarmLeechers else { return nil }
            return max(swarmSeeders, 0) + max(swarmLeechers, 0)
        }

        /// Libtorrent's current swarm estimate. Prefer the larger valid
        /// engine/tracker value so a stale or partial scrape cannot hide a
        /// better estimate already reported by the session.
        var swarmPeerEstimate: Int? {
            let engine: Int?
            if let engineSwarmSeeders, let engineSwarmLeechers {
                engine = max(engineSwarmSeeders, 0) + max(engineSwarmLeechers, 0)
            } else {
                engine = nil
            }
            return [trackerScrapePeerEstimate, engine, announcePeerEstimate]
                .compactMap { $0 }
                .max()
        }

        var peerEstimateSource: String {
            let tracker = trackerScrapePeerEstimate ?? -1
            let engine: Int
            if let engineSwarmSeeders, let engineSwarmLeechers {
                engine = max(engineSwarmSeeders, 0) + max(engineSwarmLeechers, 0)
            } else {
                engine = -1
            }
            if engine >= 0 && engine >= tracker { return "engine" }
            if let announcePeerEstimate, announcePeerEstimate >= tracker { return "announce" }
            if tracker >= 0 { return "tracker" }
            return "local"
        }

        /// A local lower-bound estimate used when no tracker scrape is
        /// available. It combines peers retained in the local peer list with
        /// peers that are currently eligible for a connection attempt.
        var localPeerEstimate: Int {
            max(knownPeerCount, cachedPeerCount, connectablePeers)
        }

        /// Always-present value for compact UI/API surfaces. Callers should
        /// use `hasTrackerSwarmEstimate` to distinguish a tracker-backed
        /// swarm count from this local lower bound.
        var displayedPeerEstimate: Int {
            max(swarmPeerEstimate ?? 0, localPeerEstimate)
        }

        /// Use the engine/tracker total when it is available, otherwise keep
        /// the local peer-list count. This mirrors the two useful views of a
        /// swarm without presenting a remote estimate as a connected peer.
        var peerCountDescription: String {
            if hasTrackerSwarmEstimate {
                return "\(numPeers) connected · \(max(displayedPeerEstimate, numPeers)) peers"
            }
            return "\(numPeers) connected · \(knownPeerCount) known"
        }

        var hasTrackerSwarmEstimate: Bool {
            trackerScrapePeerEstimate != nil || engineSwarmSeeders != nil || announcePeerEstimate != nil
        }

        /// Provisional checks must not overwrite durable progress. Once the
        /// engine has verified the files, accept even a genuine decrease.
        mutating func applyEngineProgress(_ value: Double, downloaded: Int64, isReady: Bool) {
            isRestoringProgress = !isReady
            guard isReady else {
                etaSeconds = nil
                return
            }
            if value.isFinite { progress = min(max(value, 0), 1) }
            downloadedBytes = max(downloaded, 0)
        }

        var activityStatusDescription: String {
            if isRestoringProgress && (status == .queued || status == .downloading) {
                return "Restoring progress…"
            }
            return status.displayName
        }

        var displayProgress: Double {
            if status == .completed { return 1 }
            return min(max(progress, 0), 1)
        }

        /// Reserve 100.0% for confirmed completion, including when the last
        /// fraction of a piece would otherwise round up to it.
        var displayProgressPercentage: Double {
            status == .completed ? 100 : min(displayProgress * 100, 99.9)
        }

        var isPending: Bool {
            switch status {
            case .completed, .failed:
                return false
            case .queued, .downloading, .paused:
                return true
            }
        }

        mutating func markWaitingForPeers(_ reason: String) {
            guard status == .queued || status == .downloading else { return }
            speedBytesPerSec = 0
            uploadSpeedBytesPerSec = 0
            etaSeconds = nil
            numPeers = 0
            connectablePeers = 0
            connectedSeeders = 0
            connectedLeechers = 0
            knownPeerCount = 0
            engineSwarmSeeders = nil
            engineSwarmLeechers = nil
            announcePeerEstimate = nil
            errorMessage = reason
        }

        var canRedownload: Bool {
            status == .completed && errorMessage == DownloadsViewModel.missingFilesErrorMessage
        }

        var seedLeechRatio: Double? {
            guard connectedLeechers > 0 else {
                return connectedSeeders > 0 ? Double(connectedSeeders) : nil
            }
            return Double(connectedSeeders) / Double(connectedLeechers)
        }

        /// These are observed connections, never a tracker or provider estimate.
        /// A stopped torrent may retain old session fields until its next event.
        var hasActivePeerConnections: Bool {
            numPeers > 0 && status != .paused && status != .failed
                && (status != .completed || isSeeding || isSeedingDesired)
        }

        var displayedSeeders: Int {
            hasActivePeerConnections ? max(connectedSeeders, 0) : 0
        }

        var displayedLeechers: Int {
            hasActivePeerConnections ? max(connectedLeechers, 0) : 0
        }

        var seederCountLabel: String { "connected seeders" }
        var leecherCountLabel: String { "connected leechers" }

        var compactSeederDescription: String {
            "\(displayedSeeders) connected \(displayedSeeders == 1 ? "seeder" : "seeders")"
        }

        var compactLeecherDescription: String {
            "\(displayedLeechers) connected \(displayedLeechers == 1 ? "leecher" : "leechers")"
        }

        var seederCountHelp: String {
            "Seeders currently connected to this torrent, reported by the native engine."
        }

        var leecherCountHelp: String {
            "Leechers currently connected to this torrent, reported by the native engine."
        }

        mutating func clearConnectedPeers() {
            numPeers = 0
            connectablePeers = 0
            connectedSeeders = 0
            connectedLeechers = 0
        }

        /// Show actual connections separately from discovered peer addresses.
        var peerCountDetails: [(label: String, value: String)] {
            func counts(_ seeds: Int, _ leeches: Int) -> String {
                let seedText = "\(max(seeds, 0)) \(seeds == 1 ? "seeder" : "seeders")"
                let leechText = "\(max(leeches, 0)) \(leeches == 1 ? "leecher" : "leechers")"
                return "\(seedText) · \(leechText)"
            }
            return [
                ("Connected", "\(hasActivePeerConnections ? numPeers : 0) peers · \(counts(displayedSeeders, displayedLeechers))"),
                ("Discovered peers", "\(knownPeerCount) peers")
            ]
        }

        var supportsLivePeerInspection: Bool {
            status == .queued || status == .downloading || isSeeding || isSeedingDesired || numPeers > 0
        }

        var seedLeechRatioFormatted: String? {
            guard let ratio = seedLeechRatio else { return nil }
            if ratio == 0 {
                return "0:1"
            } else if ratio >= 10 {
                return String(format: "%.0f:1", ratio)
            } else if ratio >= 1 {
                return String(format: "%.1f:1", ratio)
            } else {
                return String(format: "1:%.1f", 1.0 / ratio)
            }
        }

        var uploadedToDownloadedRatio: Double? {
            guard downloadedBytes > 0 else { return nil }
            return Double(uploadedBytes) / Double(downloadedBytes)
        }

        var shareRatioDescription: String? {
            guard let limit = shareRatioLimit else { return nil }
            return String(format: "Share %.2f× → %@", limit, shareRatioAction.title)
        }

        var seedingPolicyDescription: String? {
            var limits: [String] = []
            if let ratio = shareRatioLimit { limits.append(String(format: "%.2f× ratio", ratio)) }
            if let minutes = seedingTimeLimitMinutes { limits.append("\(minutes) min seeding") }
            if let minutes = inactiveSeedingTimeLimitMinutes { limits.append("\(minutes) min inactive") }
            guard !limits.isEmpty else { return nil }
            return limits.joined(separator: " or ") + " → " + shareRatioAction.title
        }

        var seedingDurationFormatted: String? {
            guard isSeeding, let start = seedingSince else { return nil }
            let elapsed = max(0, Date().timeIntervalSince(start))
            if elapsed < 60 {
                return "<1m"
            }
            let minutes = Int(elapsed) / 60
            let hours = minutes / 60
            if hours > 0 {
                return String(format: "%dh %dm", hours, minutes % 60)
            }
            return String(format: "%dm", minutes)
        }

        var previewCandidateURLs: [URL] {
            let fm = FileManager.default
            if let flattened = flattenedTargetURL {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: flattened.path, isDirectory: &isDir), !isDir.boolValue {
                    return [flattened]
                }
            }

            guard let base = storageURL ?? destinationURL else { return [] }
            if files.count > 1 {
                return []
            }
            var urls: [URL] = []

            if files.isEmpty {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: base.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        if let enumerator = fm.enumerator(at: base,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                            for case let fileURL as URL in enumerator {
                                if urls.count >= 8 { break }
                                if let isDirectory = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                                   isDirectory == false {
                                    urls.append(fileURL)
                                }
                            }
                        }
                        if urls.count != 1 {
                            return []
                        }
                    } else {
                        urls.append(base)
                    }
                }
                return urls
            }

            for entry in files {
                let candidate = base.appendingPathComponent(entry.relativePath)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue {
                    urls.append(candidate)
                }
            }
            if urls.count != 1 {
                return []
            }
            return urls
        }

        var preferredTorrentFileName: String {
            func ensureTorrentExtension(_ base: String) -> String {
                if base.lowercased().hasSuffix(".torrent") {
                    return base
                }
                return base + ".torrent"
            }

            func cleanedCandidate(from raw: String?, treatAsFileName: Bool) -> String? {
                guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                    return nil
                }
                var candidate = raw
                if treatAsFileName {
                    let components = candidate.components(separatedBy: CharacterSet(charactersIn: "/\\"))
                    candidate = components.last ?? candidate
                    if candidate.lowercased().hasSuffix(".torrent") {
                        candidate = String(candidate.dropLast(8))
                    }
                }
                let disallowed = CharacterSet(charactersIn: "\n\r\t:/\\?%*|\"<>")
                let underscore = "_".unicodeScalars.first!
                var cleaned = String.UnicodeScalarView()
                cleaned.reserveCapacity(candidate.unicodeScalars.count)
                for scalar in candidate.unicodeScalars {
                    if disallowed.contains(scalar) {
                        cleaned.append(underscore)
                    } else {
                        cleaned.append(scalar)
                    }
                }
                candidate = String(cleaned)
                candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty else { return nil }
                if candidate.compare(id.uuidString, options: .caseInsensitive) == .orderedSame {
                    return nil
                }
                if let infoHash, candidate.compare(infoHash, options: .caseInsensitive) == .orderedSame {
                    return nil
                }
                if UUID(uuidString: candidate) != nil {
                    return nil
                }
                return candidate
            }

            if let explicit = cleanedCandidate(from: torrentFileName, treatAsFileName: true) {
                return ensureTorrentExtension(explicit)
            }
            if let titleBased = cleanedCandidate(from: torrent.title, treatAsFileName: false) {
                return ensureTorrentExtension(titleBased)
            }
            if let hashBased = cleanedCandidate(from: infoHash, treatAsFileName: false) {
                return ensureTorrentExtension(hashBased)
            }
            return ensureTorrentExtension(id.uuidString.lowercased())
        }

        var preferredMagnetFileName: String {
            let torrentName = preferredTorrentFileName
            if torrentName.lowercased().hasSuffix(".torrent") {
                let base = torrentName.dropLast(8)
                return base + ".magnet"
            }
            return torrentName + ".magnet"
        }
    }

    struct ExistingDownloadMatch {
        let destinationURL: URL
        let storageURL: URL
        let flattenedTargetURL: URL?
        let totalBytes: Int64?
        let fileEntries: [Download.FileEntry]
        let infoHash: String?
    }

    struct PersistedDownload: Codable {
        struct PersistedFileEntry: Codable {
            let relativePath: String
            let length: Int64
            var isPadding: Bool? = nil
        }

        let id: UUID
        let torrent: TorrentItem
        let metadataTitle: String?
        let progress: Double
        let status: Download.Status
        let speedBytesPerSec: Int64
        let uploadSpeedBytesPerSec: Int64
        let averageSpeedBytesPerSec: Int64
        let peakSpeedBytesPerSec: Int64?
        let etaSeconds: Int?
        let completedAt: Date?
        let destinationURL: URL?
        let storageURL: URL?
        let contentRootURL: URL?
        let storageBookmark: Data?
        let flattenedTargetURL: URL?
        let totalBytes: Int64?
        let downloadedBytes: Int64
        let uploadedBytes: Int64
        let numPeers: Int
        let connectedSeeders: Int
        let connectedLeechers: Int
        let knownPeerCount: Int?
        let swarmSeeders: Int?
        let swarmLeechers: Int?
        let errorMessage: String?
        let infoHash: String?
        let files: [PersistedFileEntry]
        let torrentFileName: String?
        let isSeedOnly: Bool?
        let isSeeding: Bool
        let isSeedingDesired: Bool
        let seedingSince: Date?
        let startedAt: Date?
        let hasAnnouncedCompletion: Bool
        let queuePriority: Int?
        let isForceStarted: Bool?
        let isSequentialDownload: Bool?
        let selectedFileIndices: [Int]?
        let filePriorities: [Int]?
        let firstLastPiecePriority: Bool?
        let downloadLimitBytesPerSec: Int64?
        let uploadLimitBytesPerSec: Int64?
        let maxUploads: Int?
        let category: String?
        let tags: [String]?
        let shareRatioLimit: Double?
        let shareRatioAction: Download.ShareRatioAction?
        let seedingTimeLimitMinutes: Int?
        let inactiveSeedingTimeLimitMinutes: Int?
        let seedingTimeSeconds: Int64?
        let inactiveSeedingTimeSeconds: Int64?

        @MainActor init(download: Download) {
            id = download.id
            torrent = download.torrent
            metadataTitle = download.metadataTitle
            progress = download.progress
            status = download.status
            speedBytesPerSec = download.speedBytesPerSec
            uploadSpeedBytesPerSec = download.uploadSpeedBytesPerSec
            averageSpeedBytesPerSec = download.averageSpeedBytesPerSec
            peakSpeedBytesPerSec = download.peakSpeedBytesPerSec
            etaSeconds = download.etaSeconds
            completedAt = download.completedAt
            destinationURL = download.destinationURL
            storageURL = download.storageURL
            contentRootURL = download.contentRootURL
            storageBookmark = download.storageBookmark
            flattenedTargetURL = download.flattenedTargetURL
            totalBytes = download.totalBytes
            downloadedBytes = download.downloadedBytes
            uploadedBytes = download.uploadedBytes
            numPeers = download.numPeers
            connectedSeeders = download.connectedSeeders
            connectedLeechers = download.connectedLeechers
            knownPeerCount = download.knownPeerCount
            swarmSeeders = download.swarmSeeders
            swarmLeechers = download.swarmLeechers
            errorMessage = download.errorMessage
            infoHash = download.infoHash
            files = download.files.map { PersistedFileEntry(relativePath: $0.relativePath, length: $0.length, isPadding: $0.isPadding) }
            torrentFileName = download.torrentFileName
            isSeedOnly = download.isSeedOnly
            isSeeding = download.isSeeding
            isSeedingDesired = download.isSeedingDesired
            seedingSince = download.seedingSince
            startedAt = download.startedAt
            hasAnnouncedCompletion = download.hasAnnouncedCompletion
            queuePriority = download.queuePriority
            isForceStarted = download.isForceStarted
            isSequentialDownload = download.isSequentialDownload
            selectedFileIndices = download.selectedFileIndices.map(Array.init)
            filePriorities = download.filePriorities
            firstLastPiecePriority = download.firstLastPiecePriority
            downloadLimitBytesPerSec = download.downloadLimitBytesPerSec
            uploadLimitBytesPerSec = download.uploadLimitBytesPerSec
            maxUploads = download.maxUploads
            category = download.category
            tags = download.tags
            shareRatioLimit = download.shareRatioLimit
            shareRatioAction = download.shareRatioAction
            seedingTimeLimitMinutes = download.seedingTimeLimitMinutes
            inactiveSeedingTimeLimitMinutes = download.inactiveSeedingTimeLimitMinutes
            seedingTimeSeconds = download.seedingTimeSeconds
            inactiveSeedingTimeSeconds = download.inactiveSeedingTimeSeconds
        }

        @MainActor func makeDownload() -> Download {
            var download = Download(
                id: id,
                torrent: torrent,
                progress: progress,
                status: status,
                speedBytesPerSec: speedBytesPerSec,
                uploadSpeedBytesPerSec: uploadSpeedBytesPerSec,
                averageSpeedBytesPerSec: averageSpeedBytesPerSec,
                peakSpeedBytesPerSec: peakSpeedBytesPerSec ?? 0,
                etaSeconds: etaSeconds,
                completedAt: completedAt,
                destinationURL: destinationURL,
                storageURL: storageURL,
                storageBookmark: storageBookmark,
                flattenedTargetURL: flattenedTargetURL,
                totalBytes: totalBytes,
                downloadedBytes: downloadedBytes,
                uploadedBytes: uploadedBytes,
                numPeers: numPeers,
                connectedSeeders: connectedSeeders,
                connectedLeechers: connectedLeechers,
                knownPeerCount: knownPeerCount ?? max(connectedSeeders + connectedLeechers, numPeers),
                swarmSeeders: swarmSeeders,
                swarmLeechers: swarmLeechers,
                errorMessage: errorMessage,
                infoHash: infoHash,
                files: files.map { Download.FileEntry(relativePath: $0.relativePath, length: $0.length, isPadding: $0.isPadding ?? false) },
                torrentData: nil,
                torrentFileName: torrentFileName,
                isSeeding: isSeeding,
                seedingSince: seedingSince,
                startedAt: startedAt,
                hasAnnouncedCompletion: hasAnnouncedCompletion,
                queuePriority: queuePriority ?? 0,
                isForceStarted: isForceStarted ?? false,
                isSequentialDownload: isSequentialDownload ?? false,
                selectedFileIndices: selectedFileIndices.map(Set.init),
                filePriorities: filePriorities,
                firstLastPiecePriority: firstLastPiecePriority ?? false,
                downloadLimitBytesPerSec: downloadLimitBytesPerSec ?? 0,
                uploadLimitBytesPerSec: uploadLimitBytesPerSec ?? 0,
                maxUploads: maxUploads ?? 4,
                category: category ?? "",
                tags: tags ?? [],
                shareRatioLimit: shareRatioLimit,
                shareRatioAction: shareRatioAction ?? .none,
                seedingTimeLimitMinutes: seedingTimeLimitMinutes,
                inactiveSeedingTimeLimitMinutes: inactiveSeedingTimeLimitMinutes
            )
            download.seedingTimeSeconds = max(seedingTimeSeconds ?? 0, 0)
            download.inactiveSeedingTimeSeconds = max(inactiveSeedingTimeSeconds ?? 0, 0)
            download.metadataTitle = metadataTitle
            download.contentRootURL = contentRootURL
            download.isSeedOnly = isSeedOnly ?? false
            download.isSeedingDesired = isSeedingDesired
            return download
        }
    }

    enum AddTorrentResult: Equatable {
        case added
        case duplicate(title: String?)
        case failed(message: String)
    }


}
