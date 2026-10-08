//
//  DownloadsViewModel+FileValidation.swift
//  Torravia
//

import Foundation

@MainActor
extension DownloadsViewModel {
    nonisolated static func isIgnorableResumeWarning(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("resume snapshot failed")
            && normalized.contains("resume data was not generated")
            && normalized.contains("not modified since last save")
    }

    func updateMissingFilesMonitorLifecycle() {
        let shouldMonitor = downloads.contains { download in
            download.status == .completed && (download.isSeeding || download.isSeedingDesired)
        }
        if shouldMonitor {
            if missingFilesMonitorTask == nil {
                startMissingFilesMonitor()
            }
        } else {
            missingFilesMonitorTask?.cancel()
            missingFilesMonitorTask = nil
        }
    }

    private func startMissingFilesMonitor() {
        missingFilesMonitorTask?.cancel()
        missingFilesMonitorTask = Task(priority: .utility) { [weak self] in
            await self?.monitorSeedingFiles()
        }
    }

    private func monitorSeedingFiles() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.missingFilesCheckIntervalNanoseconds)
            } catch {
                return
            }
            await validateSeedingSources()
        }
    }

    private struct SeedingFileCheckSnapshot: Sendable {
        let id: UUID
        let basePath: String
        let files: [String]
        let previousError: String?
    }

    private func validateSeedingSources() async {
        let candidates = downloads
            .filter { $0.status == .completed && ($0.isSeeding || $0.isSeedingDesired) }
            .compactMap { download -> SeedingFileCheckSnapshot? in
                guard let baseURL = download.storageURL ?? download.destinationURL else { return nil }
                return SeedingFileCheckSnapshot(
                    id: download.id,
                    basePath: baseURL.path,
                    files: download.files.filter { !$0.isPadding }.map(\.relativePath),
                    previousError: download.errorMessage
                )
            }

        guard !candidates.isEmpty else { return }

        let missingIDs: Set<UUID> = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var missing: Set<UUID> = []
            missing.reserveCapacity(candidates.count)

            for snapshot in candidates {
                let baseURL = URL(fileURLWithPath: snapshot.basePath, isDirectory: true)
                let exists: Bool
                if snapshot.files.isEmpty {
                    exists = fm.fileExists(atPath: baseURL.path)
                } else {
                    var allPresent = true
                    for rel in snapshot.files {
                        let candidateURL = URL(fileURLWithPath: rel, relativeTo: baseURL).standardizedFileURL
                        if !fm.fileExists(atPath: candidateURL.path) {
                            allPresent = false
                            break
                        }
                    }
                    exists = allPresent
                }
                if !exists {
                    missing.insert(snapshot.id)
                }
            }
            return missing
        }.value

        for snapshot in candidates {
            let isMissing = missingIDs.contains(snapshot.id)
            if isMissing {
                guard snapshot.previousError != Self.missingFilesErrorMessage,
                      let current = downloads.first(where: { $0.id == snapshot.id }) else { continue }
                handleMissingFiles(for: current)
            } else if snapshot.previousError == Self.missingFilesErrorMessage {
                update(downloadID: snapshot.id) { d in
                    if d.errorMessage == Self.missingFilesErrorMessage {
                        d.errorMessage = nil
                    }
                }
            }
        }
    }

    private func handleMissingFiles(for download: Download) {
        let wasSeeding = download.isSeeding
        update(downloadID: download.id) { d in
            d.isSeeding = false
            d.isSeedingDesired = false
            d.seedingSince = nil
            d.uploadSpeedBytesPerSec = 0
            d.numPeers = 0
            d.connectablePeers = 0
            d.connectedSeeders = 0
            d.connectedLeechers = 0
            d.knownPeerCount = 0
            d.errorMessage = Self.missingFilesErrorMessage
        }
        guard wasSeeding else { return }
        Task(priority: .utility) { [session, idString = download.id.uuidString] in
            await session.stopSeeding(id: idString)
        }
    }

    func clearErrorIfNotMissing(_ download: inout Download) {
        if download.errorMessage == Self.missingFilesErrorMessage {
            return
        }
        download.errorMessage = nil
    }

    func hasAllRequiredFiles(for download: Download) -> Bool {
        guard let baseURL = download.storageURL ?? download.destinationURL else { return false }
        let fileManager = FileManager.default
        if download.files.isEmpty {
            return fileManager.fileExists(atPath: baseURL.path)
        }
        for entry in download.files {
            let candidate = Self.expectedFileURL(for: entry.relativePath, baseURL: baseURL)
            if !fileManager.fileExists(atPath: candidate.path) {
                return false
            }
        }
        return true
    }

    private static func expectedFileURL(for relativePath: String, baseURL: URL) -> URL {
        if relativePath.isEmpty {
            return baseURL.standardizedFileURL
        }
        let directory = URL(fileURLWithPath: baseURL.path, isDirectory: true)
        return URL(fileURLWithPath: relativePath, relativeTo: directory).standardizedFileURL
    }
}
