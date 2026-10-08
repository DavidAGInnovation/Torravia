//
//  DownloadsViewModel+DownloadActions.swift
//  Torravia
//
//  User-facing queue, file, transfer, and seeding commands.
//

import Foundation

@MainActor
extension DownloadsViewModel {
    func pause(_ download: Download) {
        Task(priority: .userInitiated) { [session] in
            await session.pauseTorrent(id: download.id.uuidString)
        }
        update(downloadID: download.id) { d in
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
        cancelNoPeersTimeout(for: download.id)
    }

    func resume(_ download: Download) {
        guard let current = downloads.first(where: { $0.id == download.id }) else { return }
        if current.isSeedOnly { restartOriginalSeed(current); return }
        switch current.status {
        case .completed:
            return
        case .paused:
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let latest = await MainActor.run { self.downloads.first(where: { $0.id == download.id }) ?? current }
                let input = self.sessionInput(for: latest)
                let destination = self.sessionDestinationDirectory(for: latest)
                let didResume = await self.session.resumeTorrent(id: download.id.uuidString,
                                                                 input: input,
                                                                 destination: destination,
                                                                 contentRoot: latest.contentRootURL,
                                                                 filePaths: latest.contentRootURL == nil ? [] : latest.files.map(\.relativePath),
                                            seedOnly: latest.isSeedOnly)
                await MainActor.run {
                    guard let latest = self.downloads.first(where: { $0.id == download.id }) else { return }
                    if didResume {
                        self.update(downloadID: download.id) { d in
                            d.status = .downloading
                            self.clearErrorIfNotMissing(&d)
                        }
                        if let latest = self.downloads.first(where: { $0.id == download.id }) {
                            self.scheduleNoPeersTimeout(for: latest)
                        }
                    } else {
                        let destination = latest.storageURL ?? latest.destinationURL ?? self.makeDestinationDirectory(for: latest.torrent)
                        self.beginDownload(for: latest, at: destination)
                    }
                }
            }
        default:
            if let destination = current.storageURL ?? current.destinationURL {
                beginDownload(for: current, at: destination)
            } else {
                beginDownload(for: current, at: makeDestinationDirectory(for: current.torrent))
            }
        }
    }

    func forceStart(_ download: Download) {
        if download.isSeedOnly { restartOriginalSeed(download); return }
        Task(priority: .userInitiated) { [session] in
            await session.forceStartTorrent(id: download.id.uuidString)
        }
        update(downloadID: download.id) { d in
            d.status = .downloading
            d.errorMessage = nil
            d.isForceStarted = true
        }
    }

    func moveToTop(_ download: Download) {
        update(downloadID: download.id) { $0.queuePriority = 1 }
        reorderDownload(download.id, to: 0)
        Task(priority: .userInitiated) { [session] in
            await session.setQueuePosition(id: download.id.uuidString, top: true)
        }
    }

    func moveToBottom(_ download: Download) {
        update(downloadID: download.id) { $0.queuePriority = -1 }
        reorderDownload(download.id, to: downloads.count - 1)
        Task(priority: .userInitiated) { [session] in
            await session.setQueuePosition(id: download.id.uuidString, top: false)
        }
    }

    func moveUp(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index > 0 else { return }
        update(downloadID: download.id) { $0.queuePriority = 0 }
        reorderDownload(download.id, to: index - 1)
        Task(priority: .userInitiated) { [session] in
            await session.moveQueuePosition(id: download.id.uuidString, up: true)
        }
    }

    func moveDown(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), index + 1 < downloads.count else { return }
        update(downloadID: download.id) { $0.queuePriority = 0 }
        reorderDownload(download.id, to: index + 1)
        Task(priority: .userInitiated) { [session] in
            await session.moveQueuePosition(id: download.id.uuidString, up: false)
        }
    }

    func setQueuePriority(_ priority: Int, for download: Download) {
        switch min(max(priority, -1), 1) {
        case 1: moveToTop(download)
        case -1: moveToBottom(download)
        default:
            update(downloadID: download.id) { $0.queuePriority = 0 }
        }
    }

    /// Keep the user-visible queue in the same order as the native session.
    /// The array is persisted as-is, so a rebuild/relaunch does not silently
    /// undo a manual queue move.
    private func reorderDownload(_ id: UUID, to targetIndex: Int) {
        guard let currentIndex = downloads.firstIndex(where: { $0.id == id }),
              !downloads.isEmpty else { return }
        let clampedTarget = min(max(targetIndex, 0), downloads.count - 1)
        guard currentIndex != clampedTarget else { return }
        var reordered = downloads
        let item = reordered.remove(at: currentIndex)
        reordered.insert(item, at: min(clampedTarget, reordered.count))
        replaceDownloads(reordered)
    }

    func forceRecheck(_ download: Download) {
        update(downloadID: download.id) { d in
            d.status = .downloading
            d.errorMessage = "Verifying existing files…"
        }
        Task(priority: .userInitiated) { [session] in
            await session.forceRecheckTorrent(id: download.id.uuidString)
        }
    }

    func setSequentialDownload(_ enabled: Bool, for download: Download) {
        update(downloadID: download.id) { $0.isSequentialDownload = enabled }
        Task(priority: .userInitiated) { [session] in
            await session.setSequentialDownload(id: download.id.uuidString, enabled: enabled)
        }
    }

    func setFile(_ index: Int, selected: Bool, for download: Download) {
        guard index >= 0, index < download.files.count else { return }
        var selection = download.selectedFileIndices ?? Set(download.files.indices)
        if selected { selection.insert(index) } else { selection.remove(index) }
        update(downloadID: download.id) { $0.selectedFileIndices = selection }
        Task(priority: .userInitiated) { [session] in
            await session.setFileSelection(id: download.id.uuidString, selectedIndices: selection.sorted())
        }
    }

    func filePriority(at index: Int, for download: Download) -> Int {
        guard index >= 0, index < download.files.count else { return 4 }
        if let priorities = download.filePriorities, index < priorities.count {
            return priorities[index]
        }
        return download.selectedFileIndices?.contains(index) == false ? 0 : 4
    }

    func setFilePriority(_ index: Int, priority: Int, for download: Download) {
        guard index >= 0, index < download.files.count else { return }
        var priorities = download.filePriorities ?? download.files.indices.map {
            download.selectedFileIndices?.contains($0) == false ? 0 : 4
        }
        if priorities.count < download.files.count {
            priorities.append(contentsOf: repeatElement(4, count: download.files.count - priorities.count))
        }
        let clamped = min(max(priority, 0), 7)
        guard priorities[index] != clamped else { return }
        priorities[index] = clamped
        let selected = Set(priorities.enumerated().compactMap { $0.element > 0 ? $0.offset : nil })
        update(downloadID: download.id) { d in
            d.filePriorities = priorities
            d.selectedFileIndices = selected.isEmpty ? d.selectedFileIndices : selected
        }
        Task(priority: .userInitiated) { [session] in
            await session.setFilePriority(id: download.id.uuidString, index: index, priority: clamped)
            await session.setFileSelection(id: download.id.uuidString, selectedIndices: selected.sorted())
        }
    }

    func setAllFilesSelected(_ selected: Bool, for download: Download) {
        let selection = selected ? Set(download.files.indices) : []
        update(downloadID: download.id) { $0.selectedFileIndices = selection }
        Task(priority: .userInitiated) { [session] in
            await session.setFileSelection(id: download.id.uuidString, selectedIndices: selection.sorted())
        }
    }

    func setAllFilePriorities(_ priority: Int, for download: Download) {
        let clamped = min(max(priority, 0), 7)
        let priorities = download.files.indices.map { _ in clamped }
        let selection = Set(priorities.enumerated().compactMap { $0.element > 0 ? $0.offset : nil })
        update(downloadID: download.id) { d in
            d.filePriorities = priorities
            d.selectedFileIndices = selection
        }
        Task(priority: .userInitiated) { [session] in
            for index in priorities.indices {
                await session.setFilePriority(id: download.id.uuidString, index: index, priority: priorities[index])
            }
            await session.setFileSelection(id: download.id.uuidString, selectedIndices: selection.sorted())
        }
    }

    func setFirstLastPiecePriority(_ enabled: Bool, for download: Download) {
        guard enabled != download.firstLastPiecePriority else { return }
        update(downloadID: download.id) { $0.firstLastPiecePriority = enabled }
        Task(priority: .userInitiated) { [session] in
            await session.setFirstLastPiecePriority(id: download.id.uuidString, enabled: enabled)
        }
    }

    func setTorrentLimits(for download: Download,
                          downloadLimit: Int64? = nil,
                          uploadLimit: Int64? = nil,
                          maxUploads: Int? = nil) {
        let newDownloadLimit = max(downloadLimit ?? download.downloadLimitBytesPerSec, 0)
        let newUploadLimit = max(uploadLimit ?? download.uploadLimitBytesPerSec, 0)
        let newMaxUploads = max(maxUploads ?? download.maxUploads, 0)
        guard newDownloadLimit != download.downloadLimitBytesPerSec ||
                newUploadLimit != download.uploadLimitBytesPerSec ||
                newMaxUploads != download.maxUploads else { return }
        update(downloadID: download.id) { d in
            d.downloadLimitBytesPerSec = newDownloadLimit
            d.uploadLimitBytesPerSec = newUploadLimit
            d.maxUploads = newMaxUploads
        }
        Task(priority: .userInitiated) { [session] in
            await session.setTorrentLimits(id: download.id.uuidString,
                                           downloadLimit: newDownloadLimit,
                                           uploadLimit: newUploadLimit,
                                           maxUploads: newMaxUploads)
        }
    }

    func renameFile(_ index: Int, to newName: String, for download: Download) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard index >= 0, index < download.files.count,
              !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { return }
        let oldPath = download.files[index].relativePath as NSString
        let directory = oldPath.deletingLastPathComponent
        let newPath = directory.isEmpty ? name : (directory as NSString).appendingPathComponent(name)
        update(downloadID: download.id) { d in
            guard index < d.files.count else { return }
            d.files[index] = Download.FileEntry(relativePath: newPath, length: d.files[index].length)
        }
        Task(priority: .userInitiated) { [session] in
            await session.renameFile(id: download.id.uuidString, index: index, path: newPath)
        }
    }

    func banPeer(_ peer: WebTorrentSession.Event.Peer, for downloadID: UUID) {
        banPeerAddress(peer.address, for: downloadID)
    }

    func banPeerAddress(_ address: String, for downloadID: UUID) {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var rules = Set(preferences.blockedIPRanges.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        rules.insert(normalized)
        preferences.blockedIPRanges = rules.sorted().joined(separator: "\n")
        Task(priority: .userInitiated) { [session] in
            await session.banPeer(id: downloadID.uuidString, address: normalized)
        }
    }

    func cancel(_ download: Download, deleteFiles: Bool = true) {
        let deleteFiles = deleteFiles && !download.isSeedOnly
        Task(priority: .userInitiated) { [session] in
            await session.cancelTorrent(id: download.id.uuidString, deleteData: deleteFiles)
        }
        cancelNoPeersTimeout(for: download.id)
        removePersistedTorrent(for: download)
        if deleteFiles {
            removeDownloadDirectory(for: download)
        }
        if let idx = downloads.firstIndex(where: { $0.id == download.id }) {
            removeDownloadFromList(at: idx)
        }
    }

    func redownload(_ download: Download) {
        if download.isSeedOnly { restartOriginalSeed(download); return }
        guard let current = downloads.first(where: { $0.id == download.id }) else { return }
        guard current.status == .completed else {
            resume(current)
            return
        }

        let destination = current.storageURL ?? current.destinationURL ?? makeDestinationDirectory(for: current.torrent)
        cancelNoPeersTimeout(for: current.id)
        let shouldSeed = preferences.isSeedingEnabled
        update(downloadID: current.id) { d in
            d.status = .queued
            d.progress = 0
            d.speedBytesPerSec = 0
            d.uploadSpeedBytesPerSec = 0
            d.averageSpeedBytesPerSec = 0
            d.peakSpeedBytesPerSec = 0
            d.etaSeconds = nil
            d.completedAt = nil
            d.hasAnnouncedCompletion = false
            d.errorMessage = nil
            d.isSeeding = false
            d.isSeedingDesired = shouldSeed
            d.seedingSince = nil
            d.downloadedBytes = 0
            d.uploadedBytes = 0
            d.seedingTimeSeconds = 0
            d.inactiveSeedingTimeSeconds = 0
            d.clearConnectedPeers()
            d.knownPeerCount = 0
            d.swarmSeeders = nil
            d.swarmLeechers = nil
            d.engineSwarmSeeders = nil
            d.engineSwarmLeechers = nil
            d.announcePeerEstimate = nil
            if d.contentRootURL == nil { d.files = [] }
        }

        let refreshed = downloads.first(where: { $0.id == current.id }) ?? current
        beginDownload(for: refreshed, at: destination)
    }

    func setSeeding(_ enabled: Bool, for download: Download) {
        if enabled {
            startSeeding(download)
        } else {
            stopSeeding(download)
        }
    }

    func stopSeeding(_ download: Download) {
        Task(priority: .userInitiated) { [session] in
            await session.stopSeeding(id: download.id.uuidString)
        }
        update(downloadID: download.id) { d in
            d.clearConnectedPeers()
            d.isSeedingDesired = false
            d.isSeeding = false
            d.seedingSince = nil
            d.uploadSpeedBytesPerSec = 0
        }
    }

    func setSeedingForAllCompleted(_ enabled: Bool) {
        let completed = downloads.filter { $0.status == .completed }
        guard !completed.isEmpty else { return }
        if enabled {
            for download in completed {
                startSeeding(download)
            }
        } else {
            for download in completed where download.isSeeding || download.isSeedingDesired {
                stopSeeding(download)
            }
        }
    }

    var canStartSeedingAllCompleted: Bool {
        downloads.contains { $0.status == .completed && !$0.isSeeding }
    }

    var canStopSeedingAll: Bool {
        downloads.contains { $0.status == .completed && ($0.isSeeding || $0.isSeedingDesired) }
    }

    private func startSeeding(_ download: Download) {
        if download.isSeedOnly { restartOriginalSeed(download); return }
        guard let current = downloads.first(where: { $0.id == download.id }),
              current.status == .completed else { return }
        guard hasAllRequiredFiles(for: current) else {
            update(downloadID: current.id) { d in
                d.isSeedingDesired = false
                d.isSeeding = false
                d.seedingSince = nil
                d.uploadSpeedBytesPerSec = 0
                d.errorMessage = Self.missingFilesErrorMessage
            }
            return
        }
        let shouldResume = !current.isSeeding
        update(downloadID: download.id) { d in
            d.isSeedingDesired = true
            if !d.isSeeding {
                d.isSeeding = true
            }
            if d.seedingSince == nil {
                d.seedingSince = Date()
            }
            d.errorMessage = nil
        }
        if shouldResume {
            let input = sessionInput(for: current)
            let destination = sessionDestinationDirectory(for: current)
            Task(priority: .userInitiated) { [session] in
                await session.resumeTorrent(id: download.id.uuidString,
                                            input: input,
                                            destination: destination,
                                            contentRoot: current.contentRootURL,
                                            filePaths: current.contentRootURL == nil ? [] : current.files.map(\.relativePath),
                                            seedOnly: current.isSeedOnly)
            }
        }
    }
}
