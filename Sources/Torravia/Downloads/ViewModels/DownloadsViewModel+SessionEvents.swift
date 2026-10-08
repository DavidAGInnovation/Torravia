//
//  DownloadsViewModel+SessionEvents.swift
//  Torravia
//
//  Native-session event routing and coalesced progress updates.
//

import Foundation

@MainActor
extension DownloadsViewModel {
    @MainActor
    func handle(sessionEvent event: WebTorrentSession.Event) async {
        switch event {
        case .ready:
            networkStatus = nil
        case .networkStatus(let status):
            networkStatus = status
        case .peers(let snapshot):
            guard let uuid = UUID(uuidString: snapshot.id) else { return }
            peerSnapshots[uuid] = snapshot
        case .discovery(let snapshot):
            guard let uuid = UUID(uuidString: snapshot.id) else { return }
            discoverySnapshots[uuid] = snapshot
            let scrape = snapshot.trackers.compactMap { tracker -> (complete: Int, incomplete: Int, total: Int)? in
                guard let complete = tracker.scrapeComplete,
                      let incomplete = tracker.scrapeIncomplete,
                      complete >= 0,
                      incomplete >= 0 else { return nil }
                return (complete, incomplete, complete + incomplete)
            }.max { lhs, rhs in
                if lhs.total == rhs.total { return lhs.complete < rhs.complete }
                return lhs.total < rhs.total
            }
            if let scrape {
                update(downloadID: uuid) { d in
                    d.swarmSeeders = scrape.complete
                    d.swarmLeechers = scrape.incomplete
                }
            }
            if let trackerPeers = snapshot.trackerPeers {
                update(downloadID: uuid) { d in
                    d.announcePeerEstimate = max(trackerPeers, 0)
                }
            }
        case .pieceAvailability(let snapshot):
            guard let uuid = UUID(uuidString: snapshot.id) else { return }
            pieceAvailabilitySnapshots[uuid] = snapshot.pieces
        case .pieceInspection(let snapshot):
            guard let uuid = UUID(uuidString: snapshot.id) else { return }
            pieceInspections[uuid] = snapshot
        case .added(let added):
            guard let uuid = UUID(uuidString: added.id) else { return }
            let storageURL = added.path
            let fileEntries = added.files.map { Download.FileEntry(relativePath: $0.name, length: $0.length, isPadding: $0.isPadding) }
            let fileManager = FileManager.default
            update(downloadID: uuid) { d in
                let metadataTitle = added.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !metadataTitle.isEmpty { d.metadataTitle = metadataTitle }
                if d.status != .completed, d.status != .paused {
                    d.status = .downloading
                }
                d.infoHash = added.infoHash
                d.totalBytes = added.length
                let shouldPreserveFileDestination: Bool = {
                    guard let existingDestination = d.destinationURL,
                          existingDestination != storageURL else { return false }
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: existingDestination.path, isDirectory: &isDirectory) {
                        return !isDirectory.boolValue
                    }
                    return false
                }()
                if !shouldPreserveFileDestination || d.contentRootURL != nil {
                    d.destinationURL = d.contentRootURL == nil ? storageURL
                        : Self.torrentContentURL(storage: storageURL, files: fileEntries) ?? d.destinationURL
                }
                d.storageURL = storageURL
                d.flattenedTargetURL = nil
                let isResumeRecoveryMessage = d.errorMessage?.hasPrefix("Saved download state was rejected:") == true
                    || d.errorMessage?.hasPrefix("Saved download state was stale;") == true
                if !isResumeRecoveryMessage {
                    d.errorMessage = d.isSeedOnly && d.status != .completed ? "Verifying original files…" : nil
                }
                d.numPeers = max(added.connectedSeeders, 0) + max(added.connectedLeechers, 0)
                d.connectedSeeders = added.connectedSeeders
                d.connectedLeechers = added.connectedLeechers
                d.connectablePeers = added.connectablePeers
                d.knownPeerCount = max(added.knownPeers, added.connectedSeeders + added.connectedLeechers)
                d.knownSeeders = added.knownSeeders
                d.knownLeechers = added.knownLeechers
                if let swarmSeeders = added.swarmSeeders {
                    d.engineSwarmSeeders = swarmSeeders
                }
                if let swarmLeechers = added.swarmLeechers {
                    d.engineSwarmLeechers = swarmLeechers
                }
                d.files = fileEntries
                if d.torrentData == nil {
                    d.torrentData = added.metainfo
                }
                if d.torrentFileName == nil {
                    d.torrentFileName = added.name + ".torrent"
                }
                if d.startedAt == nil {
                    d.startedAt = Date()
                }
            }
            if let download = downloads.first(where: { $0.id == uuid }) {
                do {
                    _ = try persistTorrentDataIfNeeded(for: download)
                } catch {
                    print("[DownloadsViewModel] Failed to persist resolved torrent metadata (\(download.title)): \(error)")
                }
                scheduleNoPeersTimeout(for: download)
                Task(priority: .utility) { [session] in
                    if download.isSequentialDownload {
                        await session.setSequentialDownload(id: added.id, enabled: true)
                    }
                    if let selected = download.selectedFileIndices {
                        await session.setFileSelection(id: added.id, selectedIndices: selected.sorted())
                    }
                    if let priorities = download.filePriorities {
                        for (index, priority) in priorities.enumerated() where index < download.files.count {
                            await session.setFilePriority(id: added.id, index: index, priority: priority)
                        }
                    }
                    if download.firstLastPiecePriority {
                        await session.setFirstLastPiecePriority(id: added.id, enabled: true)
                    }
                    if download.downloadLimitBytesPerSec > 0 || download.uploadLimitBytesPerSec > 0 || download.maxUploads != 4 {
                        await session.setTorrentLimits(id: added.id,
                                                       downloadLimit: download.downloadLimitBytesPerSec,
                                                       uploadLimit: download.uploadLimitBytesPerSec,
                                                       maxUploads: download.maxUploads)
                    }
                    let nativeShareAction: Int = download.shareRatioAction == .pause
                        ? 1 : download.shareRatioAction == .remove ? 2 : 0
                    await session.setShareRatioPolicy(id: added.id,
                                                      limit: download.shareRatioLimit,
                                                      action: nativeShareAction,
                                                      seedingMinutes: download.seedingTimeLimitMinutes,
                                                      inactiveMinutes: download.inactiveSeedingTimeLimitMinutes,
                                                      seedingSeconds: download.seedingTimeSeconds,
                                                      inactiveSeconds: download.inactiveSeedingTimeSeconds)
                    if download.queuePriority > 0 {
                        await session.setQueuePosition(id: added.id, top: true)
                    } else if download.queuePriority < 0 {
                        await session.setQueuePosition(id: added.id, top: false)
                    }
                    if download.isForceStarted {
                        await session.forceStartTorrent(id: added.id)
                    }
                    await session.refreshDiscovery(id: added.id)
                }
            }
        case .progress(let progress):
            guard let uuid = UUID(uuidString: progress.id) else { return }
            // A status snapshot is also authoritative when a one-shot done
            // alert was rejected or missed. Never infer completion by rounding
            // the percentage; the engine must confirm verified completion.
            if progress.isProgressReady, progress.isFinished,
               let download = downloads.first(where: { $0.id == uuid }),
               download.status != .completed, !download.files.isEmpty {
                await handle(sessionEvent: .done(.init(id: progress.id, path: progress.path,
                    files: download.files.map { .init(name: $0.relativePath, length: $0.length, isPadding: $0.isPadding) })))
                return
            }
            pendingProgressEvents[uuid] = progress
            scheduleProgressFlushIfNeeded()
            if progress.downloadSpeed > 0 || progress.numPeers > 0 {
                cancelNoPeersTimeout(for: uuid)
            } else if noPeersTimeoutTasks[uuid] == nil,
                      let download = downloads.first(where: { $0.id == uuid }) {
                scheduleNoPeersTimeout(for: download)
            }
        case .done(let completed):
            guard let uuid = UUID(uuidString: completed.id) else { return }
            pendingProgressEvents.removeValue(forKey: uuid)
            let storageURL = completed.path
            let fileEntries = completed.files.map { Download.FileEntry(relativePath: $0.name, length: $0.length, isPadding: $0.isPadding) }

            // Do not trust a completion alert by itself. Fast-resume data and
            // a selected-file torrent can report `is_finished` while a file
            // on disk is still partial. Verify the files the user requested
            // before switching the row to 100%/completed.
            let selectedFileIndices = downloads.first(where: { $0.id == uuid })?.selectedFileIndices
            let filesToValidate: [Download.FileEntry] = {
                guard let selectedFileIndices else { return fileEntries }
                return selectedFileIndices.sorted().compactMap { index in
                    fileEntries.indices.contains(index) ? fileEntries[index] : nil
                }
            }()
            if !filesToValidate.isEmpty,
               let failure = Self.completedFilesValidationFailure(filesToValidate, in: storageURL) {
                update(downloadID: uuid) { d in
                    d.status = .downloading
                    d.progress = min(max(d.progress, 0), 0.999999)
                    d.speedBytesPerSec = 0
                    d.uploadSpeedBytesPerSec = 0
                    d.etaSeconds = nil
                    d.hasAnnouncedCompletion = false
                    d.completedAt = nil
                    d.isSeeding = false
                    d.isSeedingDesired = false
                    d.seedingSince = nil
                    d.storageURL = storageURL
                    d.errorMessage = "Completion check failed: \(failure). Rechecking…"
                }
                Task(priority: .utility) { [session, id = completed.id] in
                    await session.forceRecheckTorrent(id: id)
                }
                if let current = downloads.first(where: { $0.id == uuid }) {
                    scheduleNoPeersTimeout(for: current)
                }
                return
            }
            let rootFolderName = Self.commonRootFolderName(in: fileEntries)
            let allowAutoSeeding = preferences.isSeedingEnabled
            var shouldNotify = false
            var shouldStopSeeding = false
            let primaryDestination: URL = {
                if downloads.first(where: { $0.id == uuid })?.contentRootURL != nil {
                    return Self.torrentContentURL(storage: storageURL, files: fileEntries) ?? storageURL
                }
                if fileEntries.count == 1, let single = fileEntries.first {
                    return storageURL.appendingPathComponent(single.relativePath)
                }
                if let root = rootFolderName {
                    return storageURL.appendingPathComponent(root, isDirectory: true)
                }
                return storageURL
            }()
            update(downloadID: uuid) { d in
                shouldNotify = !d.hasAnnouncedCompletion
                let wasAlreadyCompleted = (d.status == .completed)
                let desiredSeeding = d.isSeedingDesired || d.isSeeding
                let shouldSeedNow = wasAlreadyCompleted ? desiredSeeding : (allowAutoSeeding || desiredSeeding)
                shouldStopSeeding = (!shouldSeedNow && !wasAlreadyCompleted)
                d.hasAnnouncedCompletion = true
                d.status = .completed
                d.progress = 1
                d.isRestoringProgress = false
                d.speedBytesPerSec = 0
                d.uploadSpeedBytesPerSec = 0
                d.etaSeconds = 0
                d.storageURL = storageURL
                d.destinationURL = primaryDestination
                d.flattenedTargetURL = nil
                d.completedAt = Date()
                d.isSeeding = shouldSeedNow
                d.isSeedingDesired = shouldSeedNow
                d.seedingSince = shouldSeedNow ? (d.seedingSince ?? Date()) : nil
                if d.totalBytes == nil {
                    let sum = fileEntries.reduce(0) { $0 + $1.length }
                    d.totalBytes = sum > 0 ? sum : d.totalBytes
                }
                d.downloadedBytes = d.totalBytes ?? d.downloadedBytes
                d.errorMessage = nil
                d.files = fileEntries
            }
            cancelNoPeersTimeout(for: uuid)
            if shouldNotify,
               let finished = downloads.first(where: { $0.id == uuid }) {
                Task.detached { [weak self] in
                    guard let self else { return }
                    await self.didCompleteDownload(finished)
                }
            }
            if shouldStopSeeding {
                Task(priority: .background) { [session] in
                    await session.stopSeeding(id: completed.id)
                }
            }
        case .paused(let idString):
            guard let uuid = UUID(uuidString: idString) else { return }
            update(downloadID: uuid) { d in
                d.status = .paused
                d.speedBytesPerSec = 0
                d.uploadSpeedBytesPerSec = 0
                d.clearConnectedPeers()
                d.etaSeconds = nil
                if d.isSeeding {
                    d.isSeeding = false
                    d.seedingSince = nil
                }
                d.isSeedingDesired = false
            }
            cancelNoPeersTimeout(for: uuid)
        case .resumed(let idString):
            guard let uuid = UUID(uuidString: idString) else { return }
            update(downloadID: uuid) { d in
                if d.status != .completed {
                    d.status = .downloading
                }
            }
            if let download = downloads.first(where: { $0.id == uuid }) {
                scheduleNoPeersTimeout(for: download)
            }
        case .cancelled(let idString):
            guard let uuid = UUID(uuidString: idString) else { return }
            peerSnapshots[uuid] = nil
            discoverySnapshots[uuid] = nil
            pieceAvailabilitySnapshots[uuid] = nil
            pieceInspections[uuid] = nil
            cancelNoPeersTimeout(for: uuid)
            guard let current = downloads.first(where: { $0.id == uuid }) else { return }
            if current.status == .failed {
                update(downloadID: uuid) { d in
                    d.isSeeding = false
                    d.isSeedingDesired = false
                    d.seedingSince = nil
                }
            } else {
                if let index = downloads.firstIndex(where: { $0.id == uuid }) {
                    removeDownloadFromList(at: index)
                }
            }
        case .seedingStopped(let idString):
            guard let uuid = UUID(uuidString: idString) else { return }
            cancelNoPeersTimeout(for: uuid)
            update(downloadID: uuid) { d in
                d.clearConnectedPeers()
                if d.isSeedingDesired {
                    d.uploadSpeedBytesPerSec = 0
                    return
                }
                d.isSeeding = false
                d.seedingSince = nil
                d.uploadSpeedBytesPerSec = 0
            }
        case .seedingLimitReached(let idString, let action, let reason):
            guard let uuid = UUID(uuidString: idString), action == "pause" else { return }
            cancelNoPeersTimeout(for: uuid)
            update(downloadID: uuid) { d in
                if d.status != .completed { d.status = .paused }
                d.speedBytesPerSec = 0
                d.uploadSpeedBytesPerSec = 0
                d.isSeeding = false
                d.isSeedingDesired = false
                d.seedingSince = nil
                d.errorMessage = reason == "inactivity" ? "Inactivity limit reached. Seeding paused." : "Seeding time limit reached. Seeding paused."
            }
        case .shareRatioReached(let idString, let action):
            guard let uuid = UUID(uuidString: idString) else { return }
            cancelNoPeersTimeout(for: uuid)
            guard action == "pause" else { return }
            update(downloadID: uuid) { d in
                if d.status != .completed {
                    d.status = .paused
                }
                d.speedBytesPerSec = 0
                d.uploadSpeedBytesPerSec = 0
                d.isSeeding = false
                d.isSeedingDesired = false
                d.seedingSince = nil
                d.errorMessage = "Share ratio limit reached. Seeding paused."
            }
        case .resumeRejected(let idString, let message):
            guard let uuid = UUID(uuidString: idString) else { return }
            cancelNoPeersTimeout(for: uuid)
            update(downloadID: uuid) { d in
                d.status = .paused
                d.speedBytesPerSec = 0
                d.uploadSpeedBytesPerSec = 0
                d.etaSeconds = nil
                d.errorMessage = "Saved download state was rejected: \(message) Press Resume to verify the existing files."
            }
        case .resumeRechecking(let idString, let message):
            guard let uuid = UUID(uuidString: idString) else { return }
            cancelNoPeersTimeout(for: uuid)
            update(downloadID: uuid) { d in
                d.status = .downloading
                // Keep the row visibly below 100% while verification is in
                // progress. A completed status is restored only after the
                // post-recheck done event confirms every piece.
                d.progress = min(max(d.progress, 0), 0.999)
                d.isRestoringProgress = true
                d.speedBytesPerSec = 0
                d.uploadSpeedBytesPerSec = 0
                d.etaSeconds = nil
                d.errorMessage = "\(message)"
            }
        case .warning(let idString, let message):
            guard let idString, let uuid = UUID(uuidString: idString) else { return }
            guard !Self.isIgnorableResumeWarning(message) else { return }
            update(downloadID: uuid) { d in
                if d.status != .failed { d.errorMessage = message }
            }
        case .storageError(let idString, let message):
            guard let uuid = UUID(uuidString: idString) else { return }
            cancelNoPeersTimeout(for: uuid)
            pendingProgressEvents.removeValue(forKey: uuid)
            update(downloadID: uuid) { d in
                d.status = .paused
                d.speedBytesPerSec = 0
                d.uploadSpeedBytesPerSec = 0
                d.etaSeconds = nil
                if d.isSeedOnly {
                    d.isSeeding = false
                    d.isSeedingDesired = false
                    d.errorMessage = "Seeding paused: \(message) Restore the original files, then press Resume."
                } else {
                    d.errorMessage = "Storage paused safely: \(message) Fix the location or free space, then press Resume."
                }
            }
        case .noPeers(let idString, let announceType):
            guard let uuid = UUID(uuidString: idString),
                  let current = downloads.first(where: { $0.id == uuid }) else { return }
            guard current.status != .completed else {
                cancelNoPeersTimeout(for: uuid)
                return
            }
            if !current.isSeedOnly { handleNoPeersWait(for: current, announceType: announceType) }
        case .error(let id, let message):
            if message == "Unknown torrent" {
                return
            }
            if let id, let uuid = UUID(uuidString: id) {
                cancelNoPeersTimeout(for: uuid)
                update(downloadID: uuid) { d in
                    d.status = .failed
                    d.speedBytesPerSec = 0
                    d.uploadSpeedBytesPerSec = 0
                    d.etaSeconds = nil
                    d.errorMessage = message
                    d.isSeeding = false
                    d.isSeedingDesired = false
                    d.seedingSince = nil
                }
            } else {
                cancelAllNoPeersTimeouts()
                updateDownloads(where: { $0.status != .completed }) { d in
                    d.status = .failed
                    d.speedBytesPerSec = 0
                    d.uploadSpeedBytesPerSec = 0
                    d.etaSeconds = nil
                    d.errorMessage = message
                    d.isSeeding = false
                    d.isSeedingDesired = false
                    d.seedingSince = nil
                }
            }
        case .stopped(let code):
            updateDownloads(where: { _ in true }) { $0.clearConnectedPeers() }
            networkStatus = nil
            peerSnapshots.removeAll()
            discoverySnapshots.removeAll()
            pieceAvailabilitySnapshots.removeAll()
            pieceInspections.removeAll()
            let message = "Torrent helper stopped (code \(code))"
            cancelAllNoPeersTimeouts()
            updateDownloads(where: { $0.status != .completed && $0.status != .paused }) { d in
                d.status = .failed
                d.speedBytesPerSec = 0
                d.uploadSpeedBytesPerSec = 0
                d.etaSeconds = nil
                d.errorMessage = message
                d.isSeeding = false
                d.isSeedingDesired = false
                d.seedingSince = nil
            }
        }
    }

    private func scheduleProgressFlushIfNeeded() {
        guard progressFlushTask == nil else { return }
        progressFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: Self.progressFlushIntervalNanoseconds)
            } catch {
                self.progressFlushTask = nil
                return
            }
            self.flushPendingProgressEvents()
            self.progressFlushTask = nil
        }
    }

    func flushPendingProgressEvents() {
        guard !pendingProgressEvents.isEmpty else { return }
        let batch = pendingProgressEvents
        pendingProgressEvents.removeAll(keepingCapacity: true)

        isApplyingProgressBatch = true
        defer { isApplyingProgressBatch = false }

        for (uuid, progress) in batch {
            applyProgressEvent(progress, to: uuid)
        }

        scheduleDownloadsPersistence()
    }

    private func applyProgressEvent(_ progress: WebTorrentSession.Event.Progress, to uuid: UUID) {
        let etaSeconds: Int? = {
            guard let remaining = progress.timeRemaining, remaining.isFinite, remaining >= 0 else { return nil }
            return Int(ceil(remaining))
        }()
        update(downloadID: uuid) { d in
            let isCompletedAndAnnounced = (d.status == .completed && d.hasAnnouncedCompletion)
            if isCompletedAndAnnounced, progress.progress.isFinite, progress.progress < 1 {
                return
            }
            if d.status == .paused || (d.isSeedOnly && d.status == .failed) { return }
            if d.status != .completed {
                d.status = progress.isQueued ? .queued : .downloading
            }
            d.applyEngineProgress(progress.progress, downloaded: progress.downloaded,
                                  isReady: progress.isProgressReady)
            if progress.downloadSpeed.isFinite && progress.downloadSpeed >= 0 {
                let sample = Int64(progress.downloadSpeed)
                d.speedBytesPerSec = sample
                d.peakSpeedBytesPerSec = max(d.peakSpeedBytesPerSec, sample)
                if sample > 0 {
                    // A short EWMA is more useful than a lifetime arithmetic
                    // average for comparing a live swarm while still
                    // smoothing the 1.5-second engine update cadence.
                    d.averageSpeedBytesPerSec = d.averageSpeedBytesPerSec == 0
                        ? sample
                        : Int64((Double(d.averageSpeedBytesPerSec) * 0.8) + (Double(sample) * 0.2))
                }
            }
            if progress.uploadSpeed.isFinite && progress.uploadSpeed >= 0 {
                d.uploadSpeedBytesPerSec = Int64(progress.uploadSpeed)
            } else {
                d.uploadSpeedBytesPerSec = 0
            }
            d.etaSeconds = progress.isProgressReady ? etaSeconds : nil
            let storageURL = progress.path
            d.storageURL = storageURL
            if d.status != .completed {
                d.destinationURL = d.contentRootURL == nil ? storageURL
                    : Self.torrentContentURL(storage: storageURL, files: d.files) ?? d.destinationURL
            }
            d.flattenedTargetURL = nil
            if progress.isProgressReady {
                d.uploadedBytes = progress.uploaded
                d.seedingTimeSeconds = max(progress.seedingTimeSeconds, d.seedingTimeSeconds)
                d.inactiveSeedingTimeSeconds = max(progress.inactiveSeedingTimeSeconds, 0)
            }
            d.numPeers = max(progress.numPeers, 0)
            d.connectablePeers = max(progress.connectablePeers, 0)
            d.connectedSeeders = progress.connectedSeeders
            d.connectedLeechers = progress.connectedLeechers
            d.knownPeerCount = max(progress.knownPeers, progress.numPeers)
            d.knownSeeders = progress.knownSeeders
            d.knownLeechers = progress.knownLeechers
            if let swarmSeeders = progress.swarmSeeders {
                d.engineSwarmSeeders = swarmSeeders
            }
            if let swarmLeechers = progress.swarmLeechers {
                d.engineSwarmLeechers = swarmLeechers
            }
            if d.isSeedOnly && d.status != .completed {
                d.errorMessage = "Verifying original files…"
            } else if !d.isSeedingDesired && [
                "Share ratio limit reached. Seeding paused.",
                "Seeding time limit reached. Seeding paused.",
                "Inactivity limit reached. Seeding paused."
            ].contains(d.errorMessage ?? "") {
                // Keep the stop reason visible through subsequent paused progress events.
            } else if progress.numPeers > 0 || !Self.isWaitingForPeersMessage(d.errorMessage) {
                self.clearErrorIfNotMissing(&d)
            }
            if d.startedAt == nil {
                d.startedAt = Date()
            }
        }
    }

    nonisolated static func completedFilesAreValid(_ entries: [Download.FileEntry],
                                                   in storageURL: URL) -> Bool {
        completedFilesValidationFailure(entries, in: storageURL) == nil
    }

    nonisolated static func completedFilesValidationFailure(_ entries: [Download.FileEntry],
                                                            in storageURL: URL) -> String? {
        let entries = entries.filter { !$0.isPadding }
        let fileManager = FileManager.default
        // Older state snapshots sometimes stored the single-file destination
        // instead of the torrent's save directory. In that case validate the
        // entry against the file itself; treating it as a directory would
        // manufacture a path such as `file.mkv/file.mkv` and reject a valid
        // completion on restart.
        var isDirectory: ObjCBool = false
        let isExistingFile = fileManager.fileExists(atPath: storageURL.path,
                                                     isDirectory: &isDirectory)
            && !isDirectory.boolValue
        // Engine save paths do not include a trailing slash. In particular,
        // sandbox Downloads aliases can be inferred as files by Foundation.
        // Mark the save root as a directory before resolving relative files.
        let baseURL = isExistingFile && entries.count == 1
            ? storageURL.deletingLastPathComponent()
            : URL(fileURLWithPath: storageURL.path, isDirectory: true)
        let directFileURL = isExistingFile && entries.count == 1 ? storageURL : nil
        let basePath = baseURL.standardizedFileURL.path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        for entry in entries {
            guard !entry.relativePath.isEmpty else { return "empty file path" }
            let candidate = (directFileURL ?? URL(fileURLWithPath: entry.relativePath,
                                                  relativeTo: baseURL)).standardizedFileURL
            // Torrent metadata should never escape the configured save path.
            guard candidate.path.hasPrefix(basePrefix) else { return "unsafe file path: \(entry.relativePath)" }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value == max(entry.length, 0) else {
                return "missing or wrong size: \(entry.relativePath)"
            }
        }
        return nil
    }
}
