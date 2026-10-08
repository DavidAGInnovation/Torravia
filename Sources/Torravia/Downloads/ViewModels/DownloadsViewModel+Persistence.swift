import TorraviaSearchCore
//
//  DownloadsViewModel+Persistence.swift
//  Torravia
//
//  Durable download-state storage, restore, and torrent-file persistence.
//

import Foundation

@MainActor
extension DownloadsViewModel {
    static func makeDownloadsPersistenceURL() -> URL {
        let fm = FileManager.default
        if let support = try? fm.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true) {
            let stateDir = support.appendingPathComponent("\(TorrentSearchSite.stateDirectoryName)/State", isDirectory: true)
            do {
                try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
                return stateDir.appendingPathComponent("downloads.json", isDirectory: false)
            } catch {
                print("[DownloadsViewModel] Failed to create state directory at \(stateDir.path): \(error)")
            }
        }
        let fallbackDir = fm.temporaryDirectory.appendingPathComponent("\(TorrentSearchSite.stateDirectoryName)State", isDirectory: true)
        try? fm.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        return fallbackDir.appendingPathComponent("downloads.json", isDirectory: false)
    }

    /// Older sandboxed builds stored state inside the app container. Development
    /// and ad-hoc builds can run outside that container, so keep those entries
    /// visible by importing the legacy state the first time the new location is
    /// opened.
    private static func legacyDownloadsPersistenceURLs(currentURL: URL) -> [URL] {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "org.torravia.Torravia"
        let containerState = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data/Library/Application Support/TorrentDownloader/State",
                                    isDirectory: true)
        let legacyURL = containerState.appendingPathComponent("downloads.json")
        guard legacyURL.standardizedFileURL != currentURL.standardizedFileURL else { return [] }
        return [legacyURL, legacyURL.appendingPathExtension("bak")]
    }

    private static func normalizedLegacySandboxURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "org.torravia.Torravia"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacyRoot = home.appendingPathComponent(
            "Library/Containers/\(bundleIdentifier)/Data/Downloads",
            isDirectory: true
        ).path
        guard url.path == legacyRoot || url.path.hasPrefix(legacyRoot + "/") else {
            return url
        }
        let suffix = String(url.path.dropFirst(legacyRoot.count))
        return home.appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private static func legacyPersistedTorrentFileURL(for download: Download) -> URL? {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "org.torravia.Torravia"
        let stateDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/\(bundleIdentifier)/Data/Library/Application Support/TorrentDownloader/ImportedTorrents",
                isDirectory: true
            )
        return stateDirectory.appendingPathComponent(
            download.id.uuidString + "-" + download.preferredTorrentFileName,
            isDirectory: false
        )
    }

    private var downloadsBackupURL: URL {
        downloadsPersistenceURL.appendingPathExtension("bak")
    }

    func scheduleDownloadsPersistence() {
        if !allowsPersistence || isRestoringPersistedDownloads { return }
        persistenceSaveTask?.cancel()
        persistenceSaveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return
            }
            await MainActor.run {
                self.persistDownloadsNow()
            }
        }
    }

    @MainActor
    func persistDownloadsNow() {
        if !allowsPersistence || isRestoringPersistedDownloads || persistenceLoadFailed { return }
        let payload = downloads.map(PersistedDownload.init)
        Self.writeDownloads(payload, to: downloadsPersistenceURL)
        persistenceSaveTask = nil
    }

    nonisolated static func writeDownloads(_ payload: [PersistedDownload], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(payload)
            let backupURL = url.appendingPathExtension("bak")
            let fileManager = FileManager.default
            // Keep the last known-good snapshot. The main file is still replaced atomically.
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: backupURL)
                try? fileManager.copyItem(at: url, to: backupURL)
            }
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[DownloadsViewModel] Failed to persist downloads: \(error)")
        }
    }

    private func decodePersistedDownloads(from url: URL) throws -> [PersistedDownload] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PersistedDownload].self, from: data)
    }

    func loadPersistedDownloadsIfAvailable() {
        let url = downloadsPersistenceURL
        let fm = FileManager.default
        let currentCandidates = [url, downloadsBackupURL]
        let legacyCandidates = Self.legacyDownloadsPersistenceURLs(currentURL: url)
        let allCandidates = currentCandidates + legacyCandidates
        guard allCandidates.contains(where: { fm.fileExists(atPath: $0.path) }) else { return }

        var decodedGroups: [[PersistedDownload]] = []
        var lastError: Error?
        var importedLegacyState = false
        for candidate in currentCandidates where fm.fileExists(atPath: candidate.path) {
            do {
                let entries = try decodePersistedDownloads(from: candidate)
                decodedGroups.append(entries)
                if candidate != url {
                    print("[DownloadsViewModel] Restored downloads from the backup state file.")
                }
                break
            } catch {
                lastError = error
            }
        }
        for candidate in legacyCandidates where fm.fileExists(atPath: candidate.path) {
            do {
                decodedGroups.append(try decodePersistedDownloads(from: candidate))
                importedLegacyState = true
            } catch {
                lastError = error
            }
        }
        guard !decodedGroups.isEmpty else {
            persistenceLoadFailed = true
            print("[DownloadsViewModel] Failed to restore downloads: \(lastError?.localizedDescription ?? "state file is unreadable")")
            return
        }
        let persisted = Self.mergePersistedDownloads(decodedGroups)
        var restored: [Download] = []
        restored.reserveCapacity(persisted.count)
        for entry in persisted {
            var download = entry.makeDownload()
            download.destinationURL = Self.normalizedLegacySandboxURL(download.destinationURL)
            download.storageURL = Self.normalizedLegacySandboxURL(download.storageURL)
            download.contentRootURL = Self.normalizedLegacySandboxURL(download.contentRootURL)
            download.flattenedTargetURL = Self.normalizedLegacySandboxURL(download.flattenedTargetURL)
            if let errorMessage = download.errorMessage,
               Self.isIgnorableResumeWarning(errorMessage) {
                download.errorMessage = nil
            }
            download.speedBytesPerSec = 0
            download.uploadSpeedBytesPerSec = 0
            download.averageSpeedBytesPerSec = 0
            download.peakSpeedBytesPerSec = 0
            download.numPeers = 0
            download.connectablePeers = 0
            download.connectedSeeders = 0
            download.connectedLeechers = 0
            download.knownPeerCount = 0
            download.swarmSeeders = nil
            download.swarmLeechers = nil
            download.engineSwarmSeeders = nil
            download.engineSwarmLeechers = nil
            download.announcePeerEstimate = nil
            if download.errorMessage == "Unknown torrent" {
                download.errorMessage = nil
                if download.status == .failed, download.progress >= 1 {
                    download.status = .completed
                    download.completedAt = download.completedAt ?? Date()
                    download.speedBytesPerSec = 0
                    download.uploadSpeedBytesPerSec = 0
                    download.etaSeconds = 0
                }
            }
            if download.status != .completed {
                download.etaSeconds = nil
                download.hasAnnouncedCompletion = false
            } else {
                download.speedBytesPerSec = 0
                download.uploadSpeedBytesPerSec = 0
            }
            if download.torrentData?.isEmpty != false {
                let torrentURLs = [
                    try? persistedTorrentFileURL(for: download),
                    Self.legacyPersistedTorrentFileURL(for: download)
                ].compactMap { $0 }
                if let persistedURL = torrentURLs.first(where: { fm.fileExists(atPath: $0.path) }),
                   let data = try? Data(contentsOf: persistedURL) {
                    download.torrentData = data
                }
            }
            if let torrentData = download.torrentData,
               let summary = try? Self.parseTorrentFile(data: torrentData),
               let reconstructedMagnet = summary.magnetLink {
                let metadataIdentity = Self.canonicalMagnetIdentity(reconstructedMagnet)
                let requestedIdentity = Self.canonicalMagnetIdentity(download.torrent.magnetLink)
                if metadataIdentity != nil,
                   requestedIdentity != nil,
                   metadataIdentity != requestedIdentity {
                    // A download ID can outlive a changed search result. Never
                    // feed metadata from the previous torrent to libtorrent:
                    // its files, size, trackers, and info-hash may all differ.
                    // Clear every resolved field so the current magnet starts
                    // fresh and is allowed to discover its own swarm.
                    removePersistedTorrentFile(for: download)
                    resetResolvedTorrentState(&download)
                } else if metadataIdentity == requestedIdentity {
                    // Older state files stored only an info-hash magnet even
                    // when the original .torrent metadata was retained
                    // separately. Restore its announce list so future resumes
                    // keep discovery behavior and tracker scrape estimates.
                    download.torrent = download.torrent.replacingMagnetLink(with: reconstructedMagnet)
                    let name = summary.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { download.metadataTitle = name }
                }
            }
            restored.append(download)
        }
        isRestoringPersistedDownloads = true
        restoreDownloads(restored)
        isRestoringPersistedDownloads = false
        if importedLegacyState {
            print("[DownloadsViewModel] Imported downloads from the previous sandbox container.")
            scheduleDownloadsPersistence()
        }
        resumeRestoredDownloads()
    }

    private static func mergePersistedDownloads(_ groups: [[PersistedDownload]]) -> [PersistedDownload] {
        var merged: [PersistedDownload] = []
        var seenIDs = Set<UUID>()
        var seenMagnets = Set<String>()

        for entry in groups.flatMap({ $0 }) {
            let identity = canonicalMagnetIdentity(entry.torrent.magnetLink)
            if seenIDs.contains(entry.id) || (identity != nil && seenMagnets.contains(identity!)) {
                continue
            }
            seenIDs.insert(entry.id)
            if let identity {
                seenMagnets.insert(identity)
            }
            merged.append(entry)
        }
        return merged
    }

    private func resumeRestoredDownloads() {
        let snapshot = downloads
        for download in snapshot {
            activateStoredSecurityScope(for: download)
            switch download.status {
            case .completed:
                activateSeedingForRestoredDownload(download)
                continue
            case .failed:
                guard Self.shouldRetryRestoredFailure(download.errorMessage) else { continue }
                let destination = download.storageURL ?? download.destinationURL ?? makeDestinationDirectory(for: download.torrent)
                update(downloadID: download.id) { d in
                    d.status = .queued
                    d.speedBytesPerSec = 0
                    d.uploadSpeedBytesPerSec = 0
                    d.averageSpeedBytesPerSec = 0
                    d.peakSpeedBytesPerSec = 0
                    d.numPeers = 0
                    d.connectablePeers = 0
                    d.connectedSeeders = 0
                    d.connectedLeechers = 0
                    d.knownPeerCount = 0
                    d.swarmSeeders = nil
                    d.swarmLeechers = nil
                    d.engineSwarmSeeders = nil
                    d.engineSwarmLeechers = nil
                    d.announcePeerEstimate = nil
                    d.etaSeconds = nil
                    d.errorMessage = nil
                }
                beginDownload(for: download, at: destination)
            case .paused:
                let shouldRecoverStaleResume = Self.shouldRecoverStaleResume(download.errorMessage)
                let recoveryDestination = download.storageURL ?? download.destinationURL ?? makeDestinationDirectory(for: download.torrent)
                update(downloadID: download.id) { d in
                    if shouldRecoverStaleResume {
                        d.status = .queued
                        d.errorMessage = nil
                    }
                    d.speedBytesPerSec = 0
                    d.uploadSpeedBytesPerSec = 0
                    d.averageSpeedBytesPerSec = 0
                    d.peakSpeedBytesPerSec = 0
                    d.numPeers = 0
                    d.connectablePeers = 0
                    d.connectedSeeders = 0
                    d.connectedLeechers = 0
                    d.knownPeerCount = 0
                    d.swarmSeeders = nil
                    d.swarmLeechers = nil
                    d.engineSwarmSeeders = nil
                    d.engineSwarmLeechers = nil
                    d.announcePeerEstimate = nil
                    d.etaSeconds = nil
                }
                if shouldRecoverStaleResume {
                    beginDownload(for: download, at: recoveryDestination)
                }
            case .queued, .downloading:
                let destination = download.storageURL ?? download.destinationURL ?? makeDestinationDirectory(for: download.torrent)
                update(downloadID: download.id) { d in
                    d.status = .queued
                    d.speedBytesPerSec = 0
                    d.uploadSpeedBytesPerSec = 0
                    d.averageSpeedBytesPerSec = 0
                    d.peakSpeedBytesPerSec = 0
                    d.numPeers = 0
                    d.connectedSeeders = 0
                    d.connectedLeechers = 0
                    d.knownPeerCount = 0
                    d.swarmSeeders = nil
                    d.swarmLeechers = nil
                    d.engineSwarmSeeders = nil
                    d.engineSwarmLeechers = nil
                    d.announcePeerEstimate = nil
                    d.etaSeconds = nil
                    d.errorMessage = nil
                }
                beginDownload(for: download, at: destination)
            }
        }
    }

    nonisolated static func shouldRetryRestoredFailure(_ message: String?) -> Bool {
        guard let message = message?.lowercased() else { return false }
        return message.contains("library not loaded")
            || message.contains("dyld[")
            || message.contains("torrent helper stopped")
            || message.contains("native torrent helper")
    }

    nonisolated static func shouldRecoverStaleResume(_ message: String?) -> Bool {
        guard let message = message?.lowercased() else { return false }
        return message.contains("saved download state was rejected:")
            || message.contains("saved download state was stale;")
    }

    private func activateSeedingForRestoredDownload(_ snapshot: Download) {
        Task(priority: .userInitiated) { [weak self] in
            await self?.registerSeedingForRestoredDownload(snapshot)
        }
    }

    @MainActor
    private func registerSeedingForRestoredDownload(_ snapshot: Download) async {
        guard let current = downloads.first(where: { $0.id == snapshot.id }) else { return }
        guard current.isSeedingDesired else { return }
        activateStoredSecurityScope(for: current)

        if current.isSeedOnly { restartOriginalSeed(current); return }
        if !preferences.isSeedingEnabled {
            update(downloadID: current.id) { d in
                d.isSeeding = false
                d.isSeedingDesired = false
                d.seedingSince = nil
            }
            return
        }

        update(downloadID: current.id) { d in
            d.isSeedingDesired = true
            if !d.isSeeding {
                d.isSeeding = true
            }
            if d.seedingSince == nil {
                d.seedingSince = Date()
            }
            d.errorMessage = nil
            d.status = .completed
        }

        guard let refreshed = downloads.first(where: { $0.id == current.id }) else { return }
        guard let storage = refreshed.storageURL ?? refreshed.destinationURL else { return }

        let destination = refreshed.destinationURL ?? storage
        let match = ExistingDownloadMatch(destinationURL: destination,
                                          storageURL: storage,
                                          flattenedTargetURL: refreshed.flattenedTargetURL,
                                          totalBytes: refreshed.totalBytes,
                                          fileEntries: refreshed.files,
                                          infoHash: refreshed.infoHash)

        await startSeedingExistingDownload(refreshed, match: match)
    }

    private func persistedTorrentDirectory() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true)
        let container = support.appendingPathComponent("\(TorrentSearchSite.stateDirectoryName)/ImportedTorrents", isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    private func persistedTorrentFileURL(for download: Download) throws -> URL {
        let container = try persistedTorrentDirectory()
        let filename = download.id.uuidString + "-" + download.preferredTorrentFileName
        return container.appendingPathComponent(filename, isDirectory: false)
    }

    private func removePersistedTorrentFile(for download: Download) {
        guard let fileURL = try? persistedTorrentFileURL(for: download) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func resetResolvedTorrentState(_ download: inout Download) {
        download.metadataTitle = nil
        download.torrentData = nil
        download.torrentFileName = nil
        download.infoHash = nil
        download.files = []
        download.totalBytes = nil
        download.progress = 0
        download.downloadedBytes = 0
        download.uploadedBytes = 0
        download.seedingTimeSeconds = 0
        download.inactiveSeedingTimeSeconds = 0
        download.speedBytesPerSec = 0
        download.uploadSpeedBytesPerSec = 0
        download.averageSpeedBytesPerSec = 0
        download.peakSpeedBytesPerSec = 0
        download.etaSeconds = nil
        download.completedAt = nil
        download.hasAnnouncedCompletion = false
        download.isSeeding = false
        download.isSeedingDesired = false
        download.seedingSince = nil
        download.status = .queued
        download.errorMessage = nil
    }

    private func invalidateStaleTorrentMetadata(for download: Download) {
        removePersistedTorrentFile(for: download)
        update(downloadID: download.id) { current in
            resetResolvedTorrentState(&current)
        }
    }

    func persistTorrentDataIfNeeded(for download: Download) throws -> URL? {
        guard let data = download.torrentData, !data.isEmpty else { return nil }

        if let summary = try? Self.parseTorrentFile(data: data),
           let reconstructedMagnet = summary.magnetLink,
           let metadataIdentity = Self.canonicalMagnetIdentity(reconstructedMagnet),
           let requestedIdentity = Self.canonicalMagnetIdentity(download.torrent.magnetLink),
           metadataIdentity != requestedIdentity {
            // This guard also covers an already-running session whose search
            // result was replaced without restarting the app.
            invalidateStaleTorrentMetadata(for: download)
            return nil
        }

        let fileURL = try persistedTorrentFileURL(for: download)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            do {
                let existing = try Data(contentsOf: fileURL)
                if existing == data {
                    return fileURL
                }
            } catch {
                try? fm.removeItem(at: fileURL)
            }
        }

        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    func resolveTorrentData(for downloadID: UUID) async -> Data? {
        if let data = downloads.first(where: { $0.id == downloadID })?.torrentData,
           !data.isEmpty {
            return data
        }

        guard let download = downloads.first(where: { $0.id == downloadID }) else {
            return nil
        }

        if let data = download.torrentData, !data.isEmpty {
            return data
        }

        if let persistedURL = try? persistedTorrentFileURL(for: download),
           FileManager.default.fileExists(atPath: persistedURL.path),
           let data = try? Data(contentsOf: persistedURL) {
            update(downloadID: downloadID) { d in
                d.torrentData = data
            }
            return data
        }

        if let source = download.torrent.sourceURL {
            if source.isFileURL {
                if let data = try? Data(contentsOf: source), !data.isEmpty {
                    update(downloadID: downloadID) { d in
                        d.torrentData = data
                    }
                    return data
                }
            } else {
                do {
                    var request = URLRequest(url: source)
                    request.setValue("application/x-bittorrent", forHTTPHeaderField: "Accept")
                    let (data, _) = try await URLSession.shared.data(for: request)
                    guard !data.isEmpty else { return nil }
                    update(downloadID: downloadID) { d in
                        d.torrentData = data
                    }
                    if let refreshed = downloads.first(where: { $0.id == downloadID }) {
                        _ = try? persistTorrentDataIfNeeded(for: refreshed)
                    }
                    return data
                } catch {
                    print("[DownloadsViewModel] Failed to fetch torrent data for export (\(download.torrent.title)): \(error)")
                }
            }
        }

        return download.torrentData
    }

    func removePersistedTorrent(for download: Download) {
        guard let fileURL = try? persistedTorrentFileURL(for: download) else { return }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            // Ignore cleanup errors; leaving the file is harmless and avoids interrupting the user flow.
        }
    }

    static func downloadRemovalURL(for download: Download) -> URL? {
        guard !download.isSeedOnly, let destination = download.destinationURL else { return nil }
        guard let root = download.contentRootURL?.standardizedFileURL else { return destination }
        let candidate = destination.standardizedFileURL
        // Only the torrent's direct child or its private staging directory is
        // owned by it. Never remove the shared download directory or siblings.
        if candidate.deletingLastPathComponent() == root { return candidate }
        let staging = root.appendingPathComponent(".TorrentScout", isDirectory: true)
            .appendingPathComponent(download.id.uuidString, isDirectory: true).standardizedFileURL
        return candidate == staging ? candidate : nil
    }

    func removeDownloadDirectory(for download: Download) {
        guard let destination = Self.downloadRemovalURL(for: download) else { return }
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
            } catch {
                print("[DownloadsViewModel] Failed to remove download directory \(destination.path): \(error)")
            }
        }
    }

}
