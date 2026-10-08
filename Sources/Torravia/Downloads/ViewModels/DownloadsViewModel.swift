import TorraviaSearchCore

//
//  DownloadsViewModel.swift
//  Torravia
//
//

import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import Network
#if os(macOS)
import AppKit
import UserNotifications
#endif


@MainActor
final class DownloadsViewModel: ObservableObject {
    nonisolated private static let unresolvedMagnetTitle = "Magnet Link"

    // MARK: - Published State
    @Published private(set) var downloads: [Download] = [] {
        didSet {
            // Keep a monotonic revision for remote clients.  Clients can pass the
            // last revision they received and avoid downloading the full list
            // when nothing changed.
            remoteRevision &+= 1
            let oldByID = Dictionary(uniqueKeysWithValues: oldValue.map { ($0.id.uuidString, $0) })
            let oldPositions = Dictionary(uniqueKeysWithValues: oldValue.enumerated().map { ($0.element.id.uuidString, $0.offset) })
            let newIDs = Set(downloads.map { $0.id.uuidString })
            for (position, download) in downloads.enumerated() {
                let key = download.id.uuidString
                if oldByID[key] != download || oldPositions[key] != position {
                    remoteTorrentRevisions[key] = remoteRevision
                }
                remoteRemovedTorrentRevisions.removeValue(forKey: key)
            }
            for download in oldValue where !newIDs.contains(download.id.uuidString) {
                let key = download.id.uuidString
                remoteRemovedTorrentRevisions[key] = remoteRevision
                remoteTorrentRevisions.removeValue(forKey: key)
            }
            if !isApplyingProgressBatch {
                scheduleDownloadsPersistence()
            }
#if os(macOS)
            requestDockTileUpdate()
#endif
            updateRuntimeLifecycle()
        }
    }
    @Published var networkStatus: WebTorrentSession.Event.NetworkStatus?
    @Published var peerSnapshots: [UUID: WebTorrentSession.Event.PeerSnapshot] = [:]
    @Published var discoverySnapshots: [UUID: WebTorrentSession.Event.DiscoverySnapshot] = [:]
    @Published var pieceAvailabilitySnapshots: [UUID: [Int]] = [:]
    @Published var pieceInspections: [UUID: WebTorrentSession.Event.PieceInspection] = [:]
    @Published var remoteControlURL: URL?
    @Published var remoteControlLANURLs: [URL] = []
    @Published var remoteControlError: String?
    let headlessOptions: HeadlessOptions?
    let isHeadless: Bool
    var remoteAllowsLAN: Bool { headlessOptions?.allowsLAN ?? preferences.remoteControlAllowsLAN }
    var remotePort: Int { headlessOptions?.port ?? preferences.remoteControlPort }
    var remoteEnabled: Bool { isHeadless || preferences.isRemoteControlEnabled }
    var alternativeWebUI: RemoteWebUIAssets?
    var alternativeWebUIError: String?
    private var loadedWebUIBookmark: Data?
    private var isShuttingDown = false
    var remoteListenerConfiguration: String?
    var remoteControlRestartTask: Task<Void, Never>?
    var bandwidthScheduleTask: Task<Void, Never>?
    var lastAppliedBandwidthLimits: [Int] = []

    /// Revision used by the incremental local-control sync endpoint.
    var remoteRevision = 0
    var remoteTorrentRevisions: [String: Int] = [:]
    var remoteRemovedTorrentRevisions: [String: Int] = [:]

    var noPeersTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private static let noPeersTimeoutNanoseconds: UInt64 = 60 * 1_000_000_000
    static let missingFilesCheckIntervalNanoseconds: UInt64 = 30 * 1_000_000_000
    static let missingFilesErrorMessage = "Files were removed from disk. Seeding has been disabled."
    var missingFilesMonitorTask: Task<Void, Never>?
    let allowsPersistence: Bool
    let downloadsPersistenceURL: URL
    let downloadLocation: DownloadLocationStore
    let automation: DownloadAutomationStore
    var activeSecurityScopedURLs: [UUID: URL] = [:]
    var isRestoringPersistedDownloads = false
    // A malformed state file must never be replaced by an empty snapshot during teardown.
    var persistenceLoadFailed = false
    var persistenceSaveTask: Task<Void, Never>?

    var isApplyingProgressBatch = false
    var pendingProgressEvents: [UUID: WebTorrentSession.Event.Progress] = [:]
    var progressFlushTask: Task<Void, Never>?
    static let progressFlushIntervalNanoseconds: UInt64 = 250_000_000

    private var runtimeShouldBeRunning = false
    private var runtimeIdleShutdownTask: Task<Void, Never>?
    private static let runtimeIdleShutdownDelayNanoseconds: UInt64 = 15 * 1_000_000_000
    var automationTask: Task<Void, Never>?
    var importedWatchedFiles = Set<String>()
    var importedRSSItems = Set<String>()
    var rssPollInProgress = false
    var rssCachedFeedData: [String: Data] = [:]
    var rssFeedStates: [String: RSSFeedState] = [:]
    static let importedRSSItemsKey = "automation.importedRSSItems"
    var remoteListener: NWListener?
    var remoteConnections: [ObjectIdentifier: NWConnection] = [:]
    let remoteControlToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var managedCategoryPaths: [String: String] = [:]
    var managedTags = Set<String>()
    static let managedCategoryPathsKey = "remote.managedCategoryPaths"
    static let managedTagsKey = "remote.managedTags"

#if os(macOS)
    var dockTileUpdateTask: Task<Void, Never>?
    var dockTileUpdateScheduled = false
    var dockTileUpdateRequested = false
    static let dockTileUpdateIntervalNanoseconds: UInt64 = 1_000_000_000
#endif
    
    // Keep failed entries visible so users can retry or inspect errors.
    var activeDownloads: [Download] {
        downloads
    }

    var activeCount: Int { activeDownloads.count }

    var pendingCount: Int {
        downloads.reduce(0) { count, download in
            download.isPending ? count + 1 : count
        }
    }

    var downloadingCount: Int {
        downloads.reduce(0) { count, download in
            download.status == .downloading ? count + 1 : count
        }
    }

    /// Replaces the in-memory list while keeping the published setter private
    /// to the main model implementation.
    func restoreDownloads(_ restored: [Download]) {
        downloads = restored
    }

    func replaceDownloads(_ updated: [Download]) {
        downloads = updated
    }

    func removeDownloadFromList(at index: Int) {
        guard downloads.indices.contains(index) else { return }
        downloads.remove(at: index)
    }

    func updateDownloads(where predicate: (Download) -> Bool,
                         mutate: (inout Download) -> Void) {
        let ids = downloads.filter(predicate).map(\.id)
        for id in ids {
            update(downloadID: id, mutate: mutate)
        }
    }

    func hasDownload(for magnetLink: String) -> Bool {
        let identity = Self.canonicalMagnetIdentity(magnetLink)
        return downloads.contains {
            if let identity {
                return Self.canonicalMagnetIdentity($0.torrent.magnetLink) == identity
            }
            return $0.torrent.magnetLink.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(magnetLink.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
    }

    func updateDestination(for downloadID: UUID, to newURL: URL, bookmarkData: Data? = nil) {
        guard let current = downloads.first(where: { $0.id == downloadID }) else { return }
        let oldDestination = current.destinationURL
        let oldStorage = current.storageURL
        let newStorage = Self.relocatedStorageURL(from: oldDestination,
                                              oldStorage: oldStorage,
                                              to: newURL)
        let newFlattened: URL?
        if let flattened = current.flattenedTargetURL,
           flattened.standardizedFileURL == oldDestination?.standardizedFileURL {
            newFlattened = newURL
        } else {
            newFlattened = current.flattenedTargetURL
        }

        let wasSeeding = current.isSeeding || current.isSeedingDesired
        if wasSeeding {
            Task(priority: .userInitiated) { [session] in
                await session.stopSeeding(id: downloadID.uuidString)
            }
        }
        if let bookmarkData {
            startSecurityScope(for: downloadID, bookmarkData: bookmarkData)
        }
        update(downloadID: downloadID) { d in
            d.destinationURL = newURL
            d.storageURL = newStorage
            if d.contentRootURL != nil { d.contentRootURL = newStorage }
            d.storageBookmark = bookmarkData ?? d.storageBookmark
            d.flattenedTargetURL = newFlattened
        }

        guard wasSeeding,
              let refreshed = downloads.first(where: { $0.id == downloadID }) else { return }
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.startSeedingExistingDownload(refreshed,
                                                    match: self.existingMatchForRelocatedDownload(refreshed))
        }
    }

    // MARK: - Private State
    let session: WebTorrentSession
    let preferences: SeedingPreferencesStore
    private var eventTask: Task<Void, Never>?
    private var preferenceCancellable: AnyCancellable?
    private var networkPreferenceCancellable: AnyCancellable?
    private var trackersBestObserver: NSObjectProtocol?
#if os(macOS)
    lazy var notificationCenter = UNUserNotificationCenter.current()
    let notificationDelegate = DownloadNotificationDelegate()
    var didRequestNotificationAuthorization = false
    var notificationAuthorizationGranted: Bool?
#endif

    init(session: WebTorrentSession = .shared,
         preferences: SeedingPreferencesStore,
         downloadLocation: DownloadLocationStore,
         automation: DownloadAutomationStore? = nil,
         persistenceURL: URL? = nil,
         startServices: Bool = true,
         headlessOptions: HeadlessOptions? = nil) {
        self.headlessOptions = headlessOptions
        self.isHeadless = headlessOptions != nil
        self.session = session
        self.allowsPersistence = startServices || persistenceURL != nil
        self.downloadsPersistenceURL = persistenceURL ?? Self.makeDownloadsPersistenceURL()
        self.preferences = preferences
        self.downloadLocation = downloadLocation
        self.automation = automation ?? DownloadAutomationStore.shared
        self.managedCategoryPaths = UserDefaults.standard.dictionary(forKey: Self.managedCategoryPathsKey) as? [String: String] ?? [:]
        self.managedTags = Set(UserDefaults.standard.stringArray(forKey: Self.managedTagsKey) ?? [])
        self.importedRSSItems = Set(UserDefaults.standard.stringArray(forKey: Self.importedRSSItemsKey) ?? [])
        configureAlternativeWebUI()
        // Offline models can exercise control routes without restoring the user’s queue.
        guard startServices else { return }
        trackersBestObserver = NotificationCenter.default.addObserver(
            forName: TrackersBestStore.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  notification.userInfo?["trackers"] is [String] else { return }
            // The list is runtime configuration, not a global tracker
            // injection. Re-send it so eligible slow torrents can use the
            // refreshed candidates without changing ordinary torrents.
            Task { @MainActor [weak self] in
                self?.applyNetworkPreferences()
            }
        }
        TrackersBestStore.shared.startRefreshing()
        applyNetworkPreferences()
        listenForSessionEvents()
        observePreferences()
#if os(macOS)
        if !isHeadless {
            requestNotificationAuthorization()
            updateDockTile()
        }
#endif
        loadPersistedDownloadsIfAvailable()
        updateRuntimeLifecycle()
        startAutomation()
        configureRemoteControl()
        startBandwidthSchedule()
    }

    deinit {
        preferenceCancellable?.cancel()
        networkPreferenceCancellable?.cancel()
        if let trackersBestObserver {
            NotificationCenter.default.removeObserver(trackersBestObserver)
        }
        eventTask?.cancel()
        missingFilesMonitorTask?.cancel()
        runtimeIdleShutdownTask?.cancel()
        automationTask?.cancel()
        bandwidthScheduleTask?.cancel()
        remoteControlRestartTask?.cancel()
        remoteListener?.cancel()
        remoteConnections.values.forEach { $0.cancel() }
        Task.detached(priority: .background) { [session] in
            await session.shutdown()
        }
        let state = MainActor.assumeIsolated { () -> (Bool, Bool, [PersistedDownload], URL) in
            persistenceSaveTask?.cancel()
            return (
                isRestoringPersistedDownloads,
                persistenceLoadFailed,
                downloads.map(PersistedDownload.init),
                downloadsPersistenceURL
            )
        }
        let (isRestoring, loadFailed, snapshot, persistenceURL) = state
        if allowsPersistence && !isRestoring && !loadFailed {
            DownloadsViewModel.writeDownloads(snapshot, to: persistenceURL)
        }
        for url in activeSecurityScopedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
#if os(macOS)
        if !isHeadless {
            Task { @MainActor in DockTileController.shared.update(with: nil) }
        }
#endif
    }

    // MARK: - Intents
    @discardableResult
    func add(from torrent: TorrentItem,
             torrentData: Data? = nil,
             torrentFileName: String? = nil,
             category: String = "") -> Bool {
        let identity = Self.canonicalMagnetIdentity(torrent.magnetLink)
        if let existingIndex = downloads.firstIndex(where: {
            if let identity {
                return Self.canonicalMagnetIdentity($0.torrent.magnetLink) == identity
            }
            return $0.torrent.magnetLink.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(torrent.magnetLink.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }) {
            let existing = downloads[existingIndex]
            if existing.isSeedOnly { return false }
            if existing.status == .completed && !existing.isSeeding {
                cancelNoPeersTimeout(for: existing.id)
                downloads.remove(at: existingIndex)
            } else {
                return false
            }
        }

        var download = Download(torrent: torrent,
                                 torrentData: torrentData,
                                 torrentFileName: torrentFileName,
                                 category: category)
        download.status = .queued
        let root = downloadRootDirectory(category: category)
        let destination = root.appendingPathComponent(".TorrentScout", isDirectory: true)
            .appendingPathComponent(download.id.uuidString, isDirectory: true)
        download.contentRootURL = root
        download.destinationURL = destination
        downloads.append(download)

        beginDownload(for: download, at: destination)
        return true
    }

    @discardableResult
    func addMagnetLink(_ link: String, title: String? = nil, category: String = "") -> UUID? {
        guard Self.isValidMagnetLink(link) else { return nil }
        let item = TorrentItem(
            title: title?.isEmpty == false ? title! : (parseDisplayTitle(from: link) ?? Self.unresolvedMagnetTitle),
            seeders: Int.random(in: 20...2000),
            leechers: Int.random(in: 5...500),
            sizeBytes: 0,
            magnetLink: link
        )
        guard add(from: item, category: category) else { return nil }
        return downloads.last?.id
    }

    func updateMetadata(for downloadID: UUID, category: String, tags: [String]) {
        update(downloadID: downloadID) { download in
            download.category = category
            download.tags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })).sorted()
        }
    }

    func setShareRatioPolicy(for downloadID: UUID, limit: Double?, action: Download.ShareRatioAction) {
        guard let download = downloads.first(where: { $0.id == downloadID }) else { return }
        setSeedingPolicy(for: downloadID, ratioLimit: limit, seedingMinutes: download.seedingTimeLimitMinutes,
            inactiveMinutes: download.inactiveSeedingTimeLimitMinutes, action: action)
    }

    func setSeedingLimits(for downloadID: UUID, seedingMinutes: Int?, inactiveMinutes: Int?,
                          action: Download.ShareRatioAction? = nil) {
        guard let download = downloads.first(where: { $0.id == downloadID }) else { return }
        setSeedingPolicy(for: downloadID, ratioLimit: download.shareRatioLimit, seedingMinutes: seedingMinutes,
            inactiveMinutes: inactiveMinutes, action: action ?? download.shareRatioAction)
    }

    func setSeedingPolicy(for downloadID: UUID, ratioLimit: Double?, seedingMinutes: Int?,
                          inactiveMinutes: Int?, action: Download.ShareRatioAction) {
        func normalize(_ value: Int?) -> Int? { value.flatMap { $0 > 0 ? min($0, 5_256_000) : nil } }
        update(downloadID: downloadID) { download in
            download.shareRatioLimit = ratioLimit.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            download.seedingTimeLimitMinutes = normalize(seedingMinutes)
            download.inactiveSeedingTimeLimitMinutes = normalize(inactiveMinutes)
            download.shareRatioAction = action
        }
        sendSeedingPolicy(for: downloadID)
    }

    func sendSeedingPolicy(for downloadID: UUID) {
        guard let download = downloads.first(where: { $0.id == downloadID }) else { return }
        let nativeAction = download.shareRatioAction == .pause ? 1 : download.shareRatioAction == .remove ? 2 : 0
        Task(priority: .utility) { [session] in
            await session.setShareRatioPolicy(id: download.id.uuidString, limit: download.shareRatioLimit,
                action: nativeAction, seedingMinutes: download.seedingTimeLimitMinutes,
                inactiveMinutes: download.inactiveSeedingTimeLimitMinutes,
                seedingSeconds: download.seedingTimeSeconds, inactiveSeconds: download.inactiveSeedingTimeSeconds)
        }
    }

    nonisolated static func resolvedTorrentTitle(currentTitle: String, metadataTitle: String) -> String {
        let resolvedMetadataTitle = metadataTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedMetadataTitle.isEmpty else { return currentTitle }
        return resolvedMetadataTitle
    }

    @discardableResult
    func addTorrentFile(at url: URL, category: String = "") async -> AddTorrentResult {
        let securityScoped = url.startAccessingSecurityScopedResource()
        defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try Self.parseTorrentFile(at: url)
            }.value

            guard let magnetLink = summary.magnetLink else {
                return .failed(message: "The torrent file is missing required metadata.")
            }

            if hasDownload(for: magnetLink) {
                return .duplicate(title: summary.name)
            }

            let torrentData = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
            let fileName = url.lastPathComponent

            let item = TorrentItem(
                title: summary.name,
                seeders: Int.random(in: 50...2500),
                leechers: Int.random(in: 10...800),
                sizeBytes: summary.totalSize ?? Int64(summary.rawSize),
                magnetLink: magnetLink,
                sourceURL: url
            )

            let added = add(from: item,
                            torrentData: torrentData,
                            torrentFileName: fileName,
                            category: category)
            return added ? .added : .duplicate(title: summary.name)
        } catch {
            print("Failed to read torrent file: \(error)")
            return .failed(message: error.localizedDescription)
        }
    }


    // MARK: - Helpers

    private func listenForSessionEvents() {
        eventTask?.cancel()
        eventTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let stream = await self.session.eventsStream()
            for await event in stream {
                await self.handle(sessionEvent: event)
            }
        }
    }

    private func updateRuntimeLifecycle() {
        guard !isShuttingDown else { return }
        updateMissingFilesMonitorLifecycle()

        let shouldRun = downloads.contains { download in
            switch download.status {
            case .queued, .downloading:
                return true
            case .completed:
                return download.isSeeding || download.isSeedingDesired
            case .paused, .failed:
                return false
            }
        }

        guard shouldRun != runtimeShouldBeRunning else { return }
        runtimeShouldBeRunning = shouldRun

        if shouldRun {
            runtimeIdleShutdownTask?.cancel()
            runtimeIdleShutdownTask = nil
            return
        }

        runtimeIdleShutdownTask?.cancel()
        runtimeIdleShutdownTask = Task.detached(priority: .background) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.runtimeIdleShutdownDelayNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            await self.session.shutdown()
        }
    }

    private func observePreferences() {
        preferenceCancellable = preferences.$isSeedingEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                // `isSeedingEnabled` controls whether newly completed downloads auto-start seeding.
                // Disabling it should not stop already active seeding sessions, but it should
                // stop keeping the runtime alive for completed items that aren't seeding.
                guard !enabled else { return }
                for download in self.downloads where download.status == .completed && download.isSeedingDesired && !download.isSeeding {
                    self.update(downloadID: download.id) { d in
                        d.isSeedingDesired = false
                    }
                }
            }

        networkPreferenceCancellable = preferences.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyNetworkPreferences()
                self?.configureRemoteControl()
            }
    }

    private func applyNetworkPreferences() {
        guard !isShuttingDown else { return }
        let configuration = preferences.networkConfiguration
        lastAppliedBandwidthLimits = [configuration.downloadLimitBytesPerSecond, configuration.uploadLimitBytesPerSecond]
        Task(priority: .utility) { [session] in
            await session.applyNetworkConfiguration(configuration)
        }
    }

    func startBandwidthSchedule() {
        bandwidthScheduleTask?.cancel()
        bandwidthScheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshScheduledBandwidth()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func refreshScheduledBandwidth(at date: Date = Date()) {
        let configuration = preferences.networkConfiguration(at: date)
        let limits = [configuration.downloadLimitBytesPerSecond, configuration.uploadLimitBytesPerSecond]
        guard limits != lastAppliedBandwidthLimits else { return }
        lastAppliedBandwidthLimits = limits
        Task(priority: .utility) { [session] in await session.applyNetworkConfiguration(configuration) }
    }

    func configureAlternativeWebUI() {
        if alternativeWebUI != nil, headlessOptions?.webUIDirectory != nil { return }
        let bookmark = preferences.remoteWebUIBookmark
        if loadedWebUIBookmark == bookmark, alternativeWebUI != nil { return }
        loadedWebUIBookmark = bookmark
        alternativeWebUI = nil
        alternativeWebUIError = nil
        do {
            if let directory = headlessOptions?.webUIDirectory {
                alternativeWebUI = try RemoteWebUIAssets(directory: directory)
            } else if let bookmark {
                alternativeWebUI = try RemoteWebUIAssets(bookmark: bookmark)
            }
        } catch {
            alternativeWebUIError = "Alternative browser interface could not load: \(error.localizedDescription)"
        }
    }

    func shutdownServices() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        preferenceCancellable?.cancel()
        networkPreferenceCancellable?.cancel()
        automationTask?.cancel()
        bandwidthScheduleTask?.cancel()
        runtimeIdleShutdownTask?.cancel()
        missingFilesMonitorTask?.cancel()
        noPeersTimeoutTasks.values.forEach { $0.cancel() }
        remoteControlRestartTask?.cancel()
        remoteListener?.cancel()
        remoteListener = nil
        remoteConnections.values.forEach { $0.cancel() }
        remoteConnections.removeAll()
        eventTask?.cancel()
        await Task.detached { [session] in await session.shutdownAndWait() }.value
        progressFlushTask?.cancel()
        flushPendingProgressEvents()
        persistenceSaveTask?.cancel()
        persistDownloadsNow()
    }

    func configureRemoteControl() {
        guard !isShuttingDown else { return }
        configureAlternativeWebUI()
        // A cancelled listener releases its socket asynchronously. Use the latest
        // preferences when cancellation finishes, including rapid settings edits.
        guard remoteControlRestartTask == nil else { return }
        let identityKey = preferences.remoteControlTLSIdentity
            .flatMap { try? JSONEncoder().encode($0).base64EncodedString() } ?? ""
        let key = "\(remoteAllowsLAN):\(remotePort):\(preferences.remoteControlUsesHTTPS):\(identityKey):\(preferences.remoteControlHostname)"
        if !remoteEnabled || remoteListenerConfiguration != key {
            let previousListener = remoteListener
            previousListener?.cancel()
            remoteConnections.values.forEach { $0.cancel() }
            remoteConnections.removeAll()
            remoteListener = nil
            remoteListenerConfiguration = nil
            remoteControlURL = nil
            remoteControlLANURLs = []
            remoteControlError = nil
            if let previousListener {
                remoteControlRestartTask = Task { [weak self, previousListener] in
                    while previousListener.state != .cancelled {
                        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                    }
                    guard let self else { return }
                    self.remoteControlRestartTask = nil
                    self.configureRemoteControl()
                }
                return
            }
        }
        if remoteEnabled && remoteListener == nil {
            remoteListenerConfiguration = key
            startRemoteControl()
        }
    }

    func peerSnapshot(for downloadID: UUID) -> WebTorrentSession.Event.PeerSnapshot? {
        peerSnapshots[downloadID]
    }

    func discoverySnapshot(for downloadID: UUID) -> WebTorrentSession.Event.DiscoverySnapshot? {
        discoverySnapshots[downloadID]
    }

    func pieceAvailability(for downloadID: UUID) -> [Int]? {
        pieceAvailabilitySnapshots[downloadID]
    }

    func pieceInspection(for downloadID: UUID) -> WebTorrentSession.Event.PieceInspection? {
        pieceInspections[downloadID]
    }

    func requestPieceAvailability(for downloadID: UUID) {
        Task(priority: .utility) { [session] in
            await session.requestPieceAvailability(id: downloadID.uuidString)
        }
    }

    func requestPieceInspection(for downloadID: UUID) {
        Task(priority: .utility) { [session] in
            await session.requestPieceInspection(id: downloadID.uuidString)
        }
    }

    func refreshDiscovery(for downloadID: UUID) {
        Task(priority: .utility) { [session] in
            await session.refreshDiscovery(id: downloadID.uuidString)
        }
    }

    func reannounce(for downloadID: UUID) {
        Task(priority: .userInitiated) { [session] in
            await session.reannounce(id: downloadID.uuidString)
            await session.refreshDiscovery(id: downloadID.uuidString)
        }
    }

    func addTracker(_ url: String, tier: Int = 0, for downloadID: UUID) {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task(priority: .userInitiated) { [session] in
            await session.addTracker(id: downloadID.uuidString, url: value, tier: tier)
            await session.refreshDiscovery(id: downloadID.uuidString)
        }
    }

    func removeTracker(_ url: String, for downloadID: UUID) {
        Task(priority: .userInitiated) { [session] in
            await session.removeTracker(id: downloadID.uuidString, url: url)
            await session.refreshDiscovery(id: downloadID.uuidString)
        }
    }

    func addWebSeed(_ url: String, for downloadID: UUID) {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task(priority: .userInitiated) { [session] in
            await session.addWebSeed(id: downloadID.uuidString, url: value)
            await session.refreshDiscovery(id: downloadID.uuidString)
        }
    }

    func removeWebSeed(_ url: String, for downloadID: UUID) {
        Task(priority: .userInitiated) { [session] in
            await session.removeWebSeed(id: downloadID.uuidString, url: url)
            await session.refreshDiscovery(id: downloadID.uuidString)
        }
    }

    func addPeer(_ address: String, for downloadID: UUID) {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task(priority: .userInitiated) { [session] in
            await session.addPeer(id: downloadID.uuidString, address: value)
        }
    }

    func setPeerInspectionEnabled(_ enabled: Bool, for downloadID: UUID) {
        if !enabled {
            peerSnapshots[downloadID] = nil
        }
        Task(priority: .utility) { [session] in
            await session.setPeerDetailsEnabled(enabled, id: downloadID.uuidString)
        }
    }

    private func noPeersMessage(for announceType: String?) -> String {
        guard let announceType, !announceType.isEmpty else {
            return "Waiting for peers. Downloaded data is preserved and the app will keep retrying."
        }
        switch announceType.lowercased() {
        case "tracker":
            return "Waiting for tracker peers. Downloaded data is preserved and the app will keep retrying."
        case "dht":
            return "Waiting for DHT peers. Downloaded data is preserved and the app will keep retrying."
        case "lsd":
            return "Waiting for local peers. Downloaded data is preserved and the app will keep retrying."
        default:
            return "Waiting for peers (\(announceType)). Downloaded data is preserved and the app will keep retrying."
        }
    }

    static func isWaitingForPeersMessage(_ message: String?) -> Bool {
        message?.hasPrefix("Waiting for ") == true
    }

    func scheduleNoPeersTimeout(for download: Download) {
        guard !download.isSeedOnly, download.status != .completed else { return }
        cancelNoPeersTimeout(for: download.id)
        guard download.status == .queued || download.status == .downloading else { return }
        let id = download.id
        let task = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.noPeersTimeoutNanoseconds)
            } catch {
                return
            }
            await MainActor.run {
                guard let self else { return }
                guard let latest = self.downloads.first(where: { $0.id == id }) else {
                    self.noPeersTimeoutTasks[id] = nil
                    return
                }
                if latest.status == .completed || latest.status == .failed {
                    self.noPeersTimeoutTasks[id] = nil
                    return
                }
                if latest.speedBytesPerSec > 0 {
                    self.noPeersTimeoutTasks[id] = nil
                    return
                }
                self.handleNoPeersWait(for: latest, announceType: nil)
            }
        }
        noPeersTimeoutTasks[id] = task
    }

    func cancelNoPeersTimeout(for id: UUID) {
        if let task = noPeersTimeoutTasks.removeValue(forKey: id) {
            task.cancel()
        }
    }

    func cancelAllNoPeersTimeouts() {
        let tasks = noPeersTimeoutTasks
        noPeersTimeoutTasks.removeAll()
        for (_, task) in tasks {
            task.cancel()
        }
    }

    func handleNoPeersWait(for download: Download, announceType: String?) {
        let reason = noPeersMessage(for: announceType)
        if download.errorMessage != reason {
            update(downloadID: download.id) { d in
                d.markWaitingForPeers(reason)
            }
        }
        cancelNoPeersTimeout(for: download.id)

        let input = sessionInput(for: download)
        let destination = sessionDestinationDirectory(for: download)
        Task(priority: .utility) { [session, id = download.id] in
            _ = await session.resumeTorrent(id: id.uuidString,
                                            input: input,
                                            destination: destination,
                                            contentRoot: download.contentRootURL,
                                            filePaths: download.contentRootURL == nil ? [] : download.files.map(\.relativePath),
                                            seedOnly: download.isSeedOnly)
        }
    }

    func update(downloadID: UUID, mutate: (inout Download) -> Void) {
        if let idx = downloads.firstIndex(where: { $0.id == downloadID }) {
            let original = downloads[idx]
            var d = original
            mutate(&d)
            if d != original {
                downloads[idx] = d
            }
        }
    }

#if os(macOS)
    func didCompleteDownload(_ download: Download) async {
        NSSound(named: NSSound.Name("Submarine"))?.play()
        scheduleCompletionNotification(for: download)
        guard !download.isSeeding else { return }
        if let destination = download.destinationURL {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } else if let source = download.torrent.sourceURL, FileManager.default.fileExists(atPath: source.path) {
            NSWorkspace.shared.activateFileViewerSelecting([source])
        }
    }
#else
    func didCompleteDownload(_ download: Download) async { }
#endif

}

#if os(macOS)
final class DownloadNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { options.insert(.sound) }
        completionHandler(options)
    }
}
#endif

extension DownloadsViewModel.Download.Status {
    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: return "clock"
        case .downloading: return "arrow.down.circle"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

// MARK: - Formatting Helpers
extension Int64 {
    var byteCountFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }

    /// Formats transfer rates with a numeric zero instead of ByteCountFormatter's
    /// localized "Zero KB" wording.
    var transferRateFormatted: String {
        self > 0 ? byteCountFormatted : "0 KB"
    }
}

extension Int {
    var byteCountFormatted: String {
        Int64(self).byteCountFormatted
    }
}

extension Int {
    var timeSpanFormatted: String {
        let seconds = self
        if seconds < 60 { return "<1m" }
        let minutes = (seconds / 60) % 60
        let hours = seconds / 3600
        if hours > 0 { return String(format: "%dh %dm", hours, minutes) }
        return String(format: "%dm", minutes)
    }
}
