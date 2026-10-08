@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

@MainActor
struct DownloadProgressTests {
    @Test func restoringEngineProgressPreservesSavedPercentageAndBytes() throws {
        let torrent = TorrentItem(title: "Paused partial download", seeders: 0, leechers: 0,
            sizeBytes: 1000, magnetLink: "")
        var download = DownloadsViewModel.Download(torrent: torrent, progress: 0.746,
            status: .downloading, etaSeconds: 100, downloadedBytes: 746)
        for provisional in [0.0, 0.2, 0.5, 1.0] {
            download.applyEngineProgress(provisional, downloaded: Int64(provisional * 1000), isReady: false)
            #expect(download.progress == 0.746)
            #expect(download.downloadedBytes == 746)
            #expect(download.etaSeconds == nil)
            #expect(download.isRestoringProgress)
            #expect(download.activityStatusDescription == "Restoring progress…")
        }
        let selected = NativeDownloadsTextView.selectableText(downloads: [download]).string
        #expect(selected.contains("74.6%"))
        #expect(selected.contains("Restoring progress…"))
        #expect(!selected.contains("ETA"))

        // Persistence during verification keeps the saved amount, not 0%.
        let restored = DownloadsViewModel.PersistedDownload(download: download).makeDownload()
        #expect(restored.progress == 0.746)
        #expect(restored.downloadedBytes == 746)

        download.applyEngineProgress(0.746, downloaded: 746, isReady: true)
        #expect(!download.isRestoringProgress)
        #expect(download.progress == 0.746)
        download.applyEngineProgress(0.75, downloaded: 750, isReady: true)
        #expect(download.progress == 0.75)
        #expect(download.downloadedBytes == 750)

        // A real check that detects missing pieces must still reduce progress.
        download.applyEngineProgress(0.5, downloaded: 500, isReady: true)
        #expect(download.progress == 0.5)
        #expect(download.downloadedBytes == 500)
        download.applyEngineProgress(0, downloaded: 0, isReady: true)
        #expect(download.progress == 0)
        #expect(download.downloadedBytes == 0)
    }

    @Test func progressReadinessSurvivesHelperMessageDecoding() throws {
        let current = try JSONDecoder().decode(WebTorrentSession.HelperMessage.self,
            from: Data(#"{"type":"progress","isProgressReady":false,"isFinished":false}"#.utf8))
        #expect(current.isProgressReady == false)
        #expect(current.isFinished == false)
        let completed = try JSONDecoder().decode(WebTorrentSession.HelperMessage.self,
            from: Data(#"{"type":"progress","isProgressReady":true,"isFinished":true}"#.utf8))
        #expect(completed.isFinished == true)
        let legacy = try JSONDecoder().decode(WebTorrentSession.HelperMessage.self,
            from: Data(#"{"type":"progress"}"#.utf8))
        #expect(legacy.isProgressReady == nil)
        #expect(legacy.isFinished == nil)
    }

    @Test func unfinishedDownloadDoesNotRoundUpToCompletedPercentage() {
        let torrent = TorrentItem(title: "Last piece", seeders: 0, leechers: 0,
                                 sizeBytes: 1000, magnetLink: "")
        for progress in [0.9995, 0.999999, 1.0] {
            var download = DownloadsViewModel.Download(torrent: torrent,
                                                       progress: progress, status: .downloading)
            let text = NativeDownloadsTextView.selectableText(downloads: [download]).string
            #expect(text.contains("99.9%"))
            #expect(!text.contains("100.0%"))
            #expect(download.progress == progress)
            download.status = .completed
            #expect(download.displayProgressPercentage == 100)
        }
    }

    @Test func completionValidationAcceptsNestedFilesAndRejectsIncompleteFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Torrent Folder/MD5", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("checksums.md5"))
        let entries = [DownloadsViewModel.Download.FileEntry(
            relativePath: "Torrent Folder/MD5/checksums.md5", length: 3)]
        #expect(DownloadsViewModel.completedFilesAreValid(entries, in: root))
        // Engine paths have no directory marker. Foundation must not resolve
        // the torrent's files beside Downloads instead of inside it.
        let unmarkedRoot = URL(fileURLWithPath: root.path, isDirectory: false)
        #expect(DownloadsViewModel.completedFilesAreValid(entries, in: unmarkedRoot))
        try Data([1]).write(to: folder.appendingPathComponent("checksums.md5"))
        #expect(!DownloadsViewModel.completedFilesAreValid(entries, in: root))
        #expect(!DownloadsViewModel.completedFilesAreValid([
            .init(relativePath: "../outside.bin", length: 0)], in: root))
    }

    @Test func waitingForPeersPreservesPartialDownload() {
        let torrent = TorrentItem(
            title: "Partial",
            seeders: 0,
            leechers: 0,
            sizeBytes: 36_646_686_037,
            magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        )
        let destination = URL(fileURLWithPath: "/tmp/Partial")
        let metadata = Data([1, 2, 3])
        var download = DownloadsViewModel.Download(
            torrent: torrent,
            progress: 0.931328,
            status: .downloading,
            speedBytesPerSec: 231,
            uploadSpeedBytesPerSec: 13,
            etaSeconds: 10_894_296,
            destinationURL: destination,
            storageURL: destination,
            totalBytes: 36_646_686_037,
            downloadedBytes: 34_130_103_637,
            numPeers: 2,
            connectedSeeders: 1,
            connectedLeechers: 1,
            torrentData: metadata
        )

        download.markWaitingForPeers("Waiting for peers.")

        #expect(download.status == .downloading)
        #expect(download.progress == 0.931328)
        #expect(download.downloadedBytes == 34_130_103_637)
        #expect(download.destinationURL == destination)
        #expect(download.storageURL == destination)
        #expect(download.torrentData == metadata)
        #expect(download.speedBytesPerSec == 0)
        #expect(download.numPeers == 0)
        #expect(download.errorMessage == "Waiting for peers.")
    }

    @Test func peerlessPartialDownloadRemainsEligibleForRetry() {
        let torrent = TorrentItem(
            title: "Partial",
            seeders: 0,
            leechers: 0,
            sizeBytes: 1_000,
            magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        )
        var download = DownloadsViewModel.Download(
            torrent: torrent,
            progress: 0.93,
            status: .downloading,
            speedBytesPerSec: 0,
            totalBytes: 1_000,
            downloadedBytes: 930,
            numPeers: 0
        )

        download.markWaitingForPeers("Waiting for peers.")

        #expect(download.status == .downloading)
        #expect(download.downloadedBytes == 930)
        #expect(download.progress == 0.93)
        #expect(download.speedBytesPerSec == 0)
        #expect(download.numPeers == 0)
    }
}
