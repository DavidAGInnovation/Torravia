import TorraviaSearchCore
//
//  DownloadsViewModel+Storage.swift
//  Torravia
//

import Foundation

@MainActor
extension DownloadsViewModel {
    func beginDownload(for download: Download, at destination: URL) {
        if download.isSeedOnly { restartOriginalSeed(download); return }
        if download.contentRootURL == nil,
           let existing = findExistingDownloadMatch(for: download, proposedDestination: destination) {
            let allowSeeding = preferences.isSeedingEnabled
            print("[DownloadsViewModel] Skipping download for \"\(download.title)\"; found existing content at \(existing.destinationURL.path)")
            update(downloadID: download.id) { d in
                d.status = .completed
                d.progress = 1
                d.speedBytesPerSec = 0
                d.uploadSpeedBytesPerSec = 0
                d.etaSeconds = 0
                d.destinationURL = existing.destinationURL
                d.storageURL = existing.storageURL
                d.flattenedTargetURL = existing.flattenedTargetURL
                d.errorMessage = nil
                if let infoHash = existing.infoHash {
                    d.infoHash = infoHash
                }
                if !existing.fileEntries.isEmpty {
                    d.files = existing.fileEntries
                }
                if let total = existing.totalBytes, total > 0 {
                    d.totalBytes = total
                    d.downloadedBytes = total
                } else if let currentTotal = d.totalBytes, currentTotal > 0 {
                    d.downloadedBytes = currentTotal
                } else if download.torrent.sizeBytes > 0 {
                    d.totalBytes = download.torrent.sizeBytes
                    d.downloadedBytes = download.torrent.sizeBytes
                } else {
                    d.downloadedBytes = 0
                }
                d.uploadedBytes = 0
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
                d.isSeeding = allowSeeding
                d.isSeedingDesired = allowSeeding
                d.seedingSince = allowSeeding ? Date() : nil
                if d.startedAt == nil {
                    d.startedAt = Date()
                }
                d.completedAt = Date()
                d.hasAnnouncedCompletion = true
            }
            if let snapshot = downloads.first(where: { $0.id == download.id }) {
                Task(priority: .userInitiated) { [weak self] in
                    await self?.startSeedingExistingDownload(snapshot, match: existing)
                }
            }
            return
        }

        let hasPartialData = download.downloadedBytes > 0 || download.progress > 0
        update(downloadID: download.id) { d in
            d.status = .queued
            d.speedBytesPerSec = 0
            d.uploadSpeedBytesPerSec = 0
            d.etaSeconds = nil
            d.destinationURL = destination
            d.storageURL = destination
            d.flattenedTargetURL = nil
            d.errorMessage = nil
            if !hasPartialData {
                d.progress = 0
                d.downloadedBytes = 0
                d.uploadedBytes = 0
            }
            d.numPeers = 0
            d.connectablePeers = 0
            d.startedAt = d.startedAt ?? Date()
        }
        if let updated = downloads.first(where: { $0.id == download.id }) {
            scheduleNoPeersTimeout(for: updated)
        }

        let torrent = download.torrent
        let id = download.id
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try ensureDirectoryExists(destination)
                let input: String
                if let persisted = try self.persistTorrentDataIfNeeded(for: download) {
                    input = persisted.path
                } else if let url = torrent.sourceURL, Self.shouldUseSourceURLForDownload(url) {
                    input = url.isFileURL ? url.path : url.absoluteString
                } else {
                    input = torrent.magnetLink
                }
                print("[DownloadsViewModel] Adding torrent with input: \(input.prefix(200))")
                try await session.addTorrent(id: id.uuidString, input: input, destination: destination,
                                             contentRoot: download.contentRootURL,
                                             filePaths: download.contentRootURL == nil ? [] : download.files.map(\.relativePath),
                                            seedOnly: download.isSeedOnly)
            } catch {
                print("[DownloadsViewModel] addTorrent failed (\(torrent.title)): \(error)")
                await self.markDownload(id: id, asFailedWith: error.localizedDescription)
            }
        }
    }

    private func findExistingDownloadMatch(for download: Download, proposedDestination: URL) -> ExistingDownloadMatch? {
        let fileManager = FileManager.default
        let parentDirectory = proposedDestination.deletingLastPathComponent()

        var summary: TorrentFileSummary?
        if let data = download.torrentData, !data.isEmpty {
            summary = try? Self.parseTorrentFile(data: data)
        }

        // A search result's advertised size is not torrent metadata and can
        // be stale or refer to a different release. Never infer completion
        // for a metadata-less magnet from directory byte totals; wait for
        // libtorrent to resolve and verify the actual pieces instead.
        guard summary != nil || !download.files.isEmpty else { return nil }

        let expectedBytes: Int64? = {
            if let total = download.totalBytes, total > 0 {
                return total
            }
            if let summarySize = summary?.totalSize, summarySize > 0 {
                return summarySize
            }
            if download.torrent.sizeBytes > 0 {
                return download.torrent.sizeBytes
            }
            return nil
        }()

        // A resolved native torrent carries its file list even when the
        // original input was a magnet. Use that as a second completeness
        // signal; byte totals alone are unsafe because a directory may
        // contain duplicate files from an interrupted/restarted download.
        let expectedFileCount = summary?.fileCount ?? (download.files.isEmpty ? nil : download.files.count)
        let allowFileMatches: Bool
        let allowDirectoryMatches: Bool
        if let count = expectedFileCount {
            allowFileMatches = count <= 1
            allowDirectoryMatches = count > 1
        } else {
            allowFileMatches = true
            allowDirectoryMatches = true
        }

        var seenPaths = Set<String>()
        var candidates: [URL] = []

        func appendCandidateURL(_ url: URL) {
            let normalized = url.standardizedFileURL
            let path = normalized.path
            guard !path.isEmpty else { return }
            if seenPaths.insert(path).inserted {
                candidates.append(normalized)
            }
        }

        let baseTitle = sanitizeFileName(download.torrent.title.isEmpty ? "Torrent" : download.torrent.title)
        appendCandidateURL(parentDirectory.appendingPathComponent(baseTitle, isDirectory: true))
        appendCandidateURL(parentDirectory.appendingPathComponent(proposedDestination.lastPathComponent, isDirectory: true))

        let trimmedSummaryName: String? = {
            guard let rawName = summary?.name else { return nil }
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        let sanitizedSummaryName: String? = {
            guard let name = trimmedSummaryName else { return nil }
            let sanitized = sanitizeFileName(name)
            return sanitized.isEmpty ? nil : sanitized
        }()

        if let summaryName = trimmedSummaryName {
            appendCandidateURL(parentDirectory.appendingPathComponent(summaryName))
            let baseFolder = parentDirectory.appendingPathComponent(baseTitle, isDirectory: true)
            appendCandidateURL(baseFolder.appendingPathComponent(summaryName))
            appendCandidateURL(proposedDestination.appendingPathComponent(summaryName))
        }
        if let sanitized = sanitizedSummaryName {
            appendCandidateURL(parentDirectory.appendingPathComponent(sanitized))
            let baseFolder = parentDirectory.appendingPathComponent(baseTitle, isDirectory: true)
            appendCandidateURL(baseFolder.appendingPathComponent(sanitized))
            appendCandidateURL(proposedDestination.appendingPathComponent(sanitized))
        }

        if let contents = try? fileManager.contentsOfDirectory(at: parentDirectory,
                                                               includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) {
            for entry in contents {
                let name = entry.lastPathComponent
                if name.hasPrefix(baseTitle + "-") {
                    appendCandidateURL(parentDirectory.appendingPathComponent(name))
                }
                if let summaryName = trimmedSummaryName, name.hasPrefix(summaryName + "-") {
                    appendCandidateURL(parentDirectory.appendingPathComponent(name))
                }
                if let sanitized = sanitizedSummaryName, name.hasPrefix(sanitized + "-") {
                    appendCandidateURL(parentDirectory.appendingPathComponent(name))
                }
            }
        }

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard allowDirectoryMatches else { continue }
                if let match = existingMatchForDirectory(at: candidate,
                                                         expectedBytes: expectedBytes,
                                                         expectedFileCount: expectedFileCount,
                                                         infoHash: summary?.infoHash) {
                    return match
                }
            } else {
                guard allowFileMatches else { continue }
                if let match = existingMatchForFile(at: candidate,
                                                    expectedBytes: expectedBytes,
                                                    infoHash: summary?.infoHash) {
                    return match
                }
            }
        }

        return nil
    }

    private func existingMatchForFile(at url: URL,
                                      expectedBytes: Int64?,
                                      infoHash: String?) -> ExistingDownloadMatch? {
        let disallowedExtensions: Set<String> = ["torrent", "magnet"]
        let lowercasedExtension = url.pathExtension.lowercased()
        if disallowedExtensions.contains(lowercasedExtension) {
            return nil
        }

        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let sizeNumber = attributes[.size] as? NSNumber else { return nil }

        let actualSize = sizeNumber.int64Value
        if actualSize == 0, let expected = expectedBytes, expected > 0 {
            return nil
        }
        if let expected = expectedBytes, expected > 0, actualSize > 0, actualSize != expected {
            return nil
        }

        let recordedSize = actualSize > 0 ? actualSize : expectedBytes ?? 0
        let entry = Download.FileEntry(relativePath: url.lastPathComponent, length: recordedSize)
        let storage = url.deletingLastPathComponent()
        return ExistingDownloadMatch(destinationURL: url,
                                     storageURL: storage,
                                     flattenedTargetURL: url,
                                     totalBytes: recordedSize > 0 ? recordedSize : expectedBytes,
                                     fileEntries: [entry],
                                     infoHash: infoHash)
    }

    private func existingMatchForDirectory(at url: URL,
                                           expectedBytes: Int64?,
                                           expectedFileCount: Int?,
                                           infoHash: String?) -> ExistingDownloadMatch? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url,
                                                      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                      options: [.skipsHiddenFiles],
                                                      errorHandler: { _, _ in true }) else { return nil }

        var entries: [Download.FileEntry] = []
        entries.reserveCapacity(expectedFileCount ?? 32)
        var totalBytes: Int64 = 0
        var actualFileCount = 0

        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard resourceValues.isRegularFile == true else { continue }
                actualFileCount += 1
                let length = Int64(resourceValues.fileSize ?? 0)
                let relative = relativePath(for: fileURL, relativeTo: url)
                entries.append(Download.FileEntry(relativePath: relative, length: length))
                if length > 0 {
                    if totalBytes > Int64.max - length {
                        totalBytes = Int64.max
                    } else {
                        totalBytes += length
                    }
                }
            } catch {
                continue
            }
        }

        guard actualFileCount > 0 else { return nil }
        // Existing-content detection is deliberately conservative. A partial
        // directory plus unrelated/duplicate files must never be promoted to
        // a completed torrent merely because its aggregate size is large.
        if let expectedCount = expectedFileCount, expectedCount > 0, actualFileCount != expectedCount {
            return nil
        }
        if let expected = expectedBytes, expected > 0, totalBytes != expected {
            return nil
        }

        let resolvedTotal = totalBytes > 0 ? totalBytes : expectedBytes
        let primaryFileURL: URL?
        if actualFileCount == 1, let first = entries.first {
            let candidate = url.appendingPathComponent(first.relativePath)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                primaryFileURL = candidate
            } else {
                primaryFileURL = nil
            }
        } else {
            primaryFileURL = nil
        }

        return ExistingDownloadMatch(destinationURL: primaryFileURL ?? url,
                                     storageURL: url,
                                     flattenedTargetURL: primaryFileURL,
                                     totalBytes: resolvedTotal,
                                     fileEntries: entries,
                                     infoHash: infoHash)
    }

    func startSeedingExistingDownload(_ download: Download, match: ExistingDownloadMatch) async {
        if download.isSeedOnly {
            guard downloads.contains(where: { $0.id == download.id && $0.isSeedingDesired }) else { return }
        }
        do {
            if !download.isSeedOnly { try ensureDirectoryExists(match.storageURL) }
            let input: String
            if let persisted = try persistTorrentDataIfNeeded(for: download) {
                input = persisted.path
            } else if let url = download.torrent.sourceURL, Self.shouldUseSourceURLForDownload(url) {
                input = url.isFileURL ? url.path : url.absoluteString
            } else {
                input = download.torrent.magnetLink
            }
            print("[DownloadsViewModel] Registering existing torrent for seeding: \(input.prefix(200))")
            let registered = await session.resumeTorrent(id: download.id.uuidString,
                                            input: input,
                                            destination: match.storageURL,
                                            contentRoot: download.contentRootURL,
                                            filePaths: download.contentRootURL == nil ? [] : download.files.map(\.relativePath),
                                            seedOnly: download.isSeedOnly)
            if download.isSeedOnly {
                if !registered {
                    await markDownload(id: download.id, asFailedWith: "The torrent engine could not start seeding. Press Resume to retry.")
                } else if let current = downloads.first(where: { $0.id == download.id }) {
                    if !current.isSeedingDesired { await session.stopSeeding(id: download.id.uuidString) }
                } else {
                    await session.cancelTorrent(id: download.id.uuidString, deleteData: false)
                }
            }
        } catch {
            await markDownload(id: download.id, asFailedWith: error.localizedDescription)
        }
    }

    private func relativePath(for fileURL: URL, relativeTo baseURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let targetPath = fileURL.standardizedFileURL.path
        guard targetPath.hasPrefix(basePath) else { return fileURL.lastPathComponent }
        let index = targetPath.index(targetPath.startIndex, offsetBy: basePath.count)
        var suffix = String(targetPath[index...])
        if suffix.hasPrefix("/") { suffix.removeFirst() }
        return suffix
    }

    private func markDownload(id: UUID, asFailedWith message: String) async {
        cancelNoPeersTimeout(for: id)
        update(downloadID: id) { d in
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

    func downloadRootDirectory(category: String = "") -> URL {
        let downloadsDir = downloadLocation.locationURL ?? DownloadLocationStore.systemDownloadsURL
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? downloadsDir
            : downloadsDir.appendingPathComponent(sanitizeFileName(trimmed), isDirectory: true)
    }

    static func torrentContentURL(storage: URL, files: [Download.FileEntry]) -> URL? {
        let files = files.filter { !$0.isPadding }
        guard !files.isEmpty else { return nil }
        let components = files.map { $0.relativePath.split(separator: "/", omittingEmptySubsequences: false) }
        guard components.allSatisfy({ !$0.isEmpty && !$0.contains("") && !$0.contains("..") && !$0.contains(".") }) else { return nil }
        let roots = Set(components.compactMap { $0.first.map(String.init) })
        guard roots.count == 1, let root = roots.first else { return nil }
        return storage.appendingPathComponent(root)
    }

    func makeDestinationDirectory(for torrent: TorrentItem, category: String = "") -> URL {
        let downloadsDir = downloadLocation.locationURL ?? DownloadLocationStore.systemDownloadsURL
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryRoot = trimmedCategory.isEmpty
            ? downloadsDir
            : downloadsDir.appendingPathComponent(sanitizeFileName(trimmedCategory), isDirectory: true)
        try? FileManager.default.createDirectory(at: categoryRoot, withIntermediateDirectories: true)
        let baseName = sanitizeFileName(torrent.title.isEmpty ? "Torrent" : torrent.title)
        var candidate = categoryRoot.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            suffix += 1
            candidate = categoryRoot.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
        }
        return candidate
    }

    func sessionInput(for download: Download) -> String {
        if let persisted = try? persistTorrentDataIfNeeded(for: download) {
            return persisted.path
        }
        if let url = download.torrent.sourceURL, Self.shouldUseSourceURLForDownload(url) {
            return url.isFileURL ? url.path : url.absoluteString
        }
        return download.torrent.magnetLink
    }

    func sessionDestinationDirectory(for download: Download) -> URL {
        if let storageURL = download.storageURL { return storageURL }
        if let destinationURL = download.destinationURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDir), !isDir.boolValue {
                return destinationURL.deletingLastPathComponent()
            }
            return destinationURL
        }
        return makeDestinationDirectory(for: download.torrent)
    }

    func startSecurityScope(for downloadID: UUID, bookmarkData: Data?) {
        guard let bookmarkData else { return }
        activeSecurityScopedURLs[downloadID]?.stopAccessingSecurityScopedResource()
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmarkData,
                              options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else { return }
            activeSecurityScopedURLs[downloadID] = url
        } catch {
            print("[DownloadsViewModel] Failed to resolve storage bookmark: \(error)")
        }
    }

    func activateStoredSecurityScope(for download: Download) {
        startSecurityScope(for: download.id, bookmarkData: download.storageBookmark)
    }

    static func relocatedStorageURL(from oldDestination: URL?,
                             oldStorage: URL?,
                             to newDestination: URL) -> URL {
        guard let oldDestination, let oldStorage else { return newDestination }
        if oldDestination.standardizedFileURL == oldStorage.standardizedFileURL { return newDestination }
        return newDestination.deletingLastPathComponent()
    }

    func existingMatchForRelocatedDownload(_ download: Download) -> ExistingDownloadMatch {
        let storage = download.storageURL ?? download.destinationURL ?? makeDestinationDirectory(for: download.torrent)
        let destination = download.destinationURL ?? storage
        return ExistingDownloadMatch(destinationURL: destination,
                                     storageURL: storage,
                                     flattenedTargetURL: download.flattenedTargetURL,
                                     totalBytes: download.totalBytes,
                                     fileEntries: download.files,
                                     infoHash: download.infoHash)
    }

    nonisolated static func commonRootFolderName(in files: [Download.FileEntry]) -> String? {
        guard !files.isEmpty else { return nil }
        var rootName: String?
        for entry in files {
            let components = splitPathComponents(entry.relativePath)
            guard components.count >= 2 else { return nil }
            let first = components[0]
            if let existing = rootName {
                if existing != first { return nil }
            } else {
                rootName = first
            }
        }
        return rootName
    }

    private nonisolated static func splitPathComponents(_ path: String) -> [String] {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map { String($0) }
    }

    private func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|\0")
        let components = name.components(separatedBy: invalid)
        let cleaned = components.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Download" : cleaned
    }

    nonisolated private func ensureDirectoryExists(_ url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        guard directoryURL != url else { return }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private static func shouldUseSourceURLForDownload(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "magnet" { return true }
        if scheme == "http" || scheme == "https" {
            return url.pathExtension.lowercased() == "torrent"
        }
        return false
    }
}
