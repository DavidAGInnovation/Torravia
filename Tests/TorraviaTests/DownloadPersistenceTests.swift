@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

@MainActor
struct DownloadPersistenceTests {
    @Test func prefersEmbeddedMetadataTitleToSearchTitle() {
        #expect(DownloadsViewModel.resolvedTorrentTitle(
            currentTitle: "Magnet Link",
            metadataTitle: "  Resolved Torrent Title  "
        ) == "Resolved Torrent Title")

        #expect(DownloadsViewModel.resolvedTorrentTitle(
            currentTitle: "Search Result Title",
            metadataTitle: "Metadata Title"
        ) == "Metadata Title")
    }

    @Test func embeddedDownloadNamePreservesSearchIdentityPathsAndLegacyPersistence() throws {
        let item = TorrentItem(title: "Pokémon Legends Z A v1 0 0 DLC 3 Switch Emulators MULTi10",
            seeders: 3, leechers: 0, sizeBytes: 10, magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        let root = URL(fileURLWithPath: "/tmp/Downloads/Pokemon Legends - Z-A [FitGirl Repack]", isDirectory: true)
        var download = DownloadsViewModel.Download(torrent: item, progress: 1, status: .completed,
            destinationURL: root, storageURL: root.deletingLastPathComponent())
        #expect(download.title == item.title)
        download.metadataTitle = "Pokemon Legends - Z-A [FitGirl Repack]"
        #expect(download.title == root.lastPathComponent)
        #expect(download.originalSearchTitle == item.title)
        #expect(download.torrent == item)
        let data = try JSONEncoder().encode(DownloadsViewModel.PersistedDownload(download: download))
        let restored = try JSONDecoder().decode(DownloadsViewModel.PersistedDownload.self, from: data).makeDownload()
        #expect(restored.title == download.title)
        #expect(restored.originalSearchTitle == item.title)
        #expect(restored.destinationURL == root)
        #expect(restored.status == .completed)
        #expect(restored.progress == 1)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "metadataTitle")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let legacyDownload = try JSONDecoder().decode(DownloadsViewModel.PersistedDownload.self, from: legacyData).makeDownload()
        #expect(legacyDownload.title == item.title)
        #expect(legacyDownload.destinationURL == root)
        #expect(DownloadsViewModel.resolvedTorrentTitle(currentTitle: item.title, metadataTitle: " ") == item.title)
    }

    @Test func torrentContentPathsKeepOnlyTheOriginalRoot() {
        let root = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        let multi = [
            DownloadsViewModel.Download.FileEntry(relativePath: "Original Torrent/a.bin", length: 10),
            DownloadsViewModel.Download.FileEntry(relativePath: "Original Torrent/subfolder/b.bin", length: 20)
        ]
        #expect(DownloadsViewModel.torrentContentURL(storage: root, files: multi)?.path == "/tmp/Downloads/Original Torrent")
        let single = [DownloadsViewModel.Download.FileEntry(relativePath: "file-2.ext", length: 10)]
        #expect(DownloadsViewModel.torrentContentURL(storage: root, files: single)?.path == "/tmp/Downloads/file-2.ext")
        for paths in [[], ["../outside.bin"], ["/outside.bin"], ["folder/../outside.bin"], ["folder/a", "other/b"]] {
            let files = paths.map { DownloadsViewModel.Download.FileEntry(relativePath: $0, length: 1) }
            #expect(DownloadsViewModel.torrentContentURL(storage: root, files: files) == nil)
        }
    }

    @Test func movedTorrentContentKeepsItsNewParentAsEngineStorage() {
        let root = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        for name in ["Original Torrent", "file-2.bin"] {
            let content = root.appendingPathComponent(name)
            let relocated = URL(fileURLWithPath: "/tmp/New Location").appendingPathComponent(name)
            let storage = DownloadsViewModel.relocatedStorageURL(from: content, oldStorage: root, to: relocated)
            #expect(storage.path == "/tmp/New Location")
        }
        let legacy = root.appendingPathComponent("Wrapper", isDirectory: true)
        let relocated = URL(fileURLWithPath: "/tmp/New Location/Wrapper", isDirectory: true)
        #expect(DownloadsViewModel.relocatedStorageURL(from: legacy, oldStorage: legacy, to: relocated) == relocated)
    }

    @Test func removingSharedDownloadsCannotRemoveTheirParentDirectory() {
        let root = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        let torrent = TorrentItem(title: "Content", seeders: 0, leechers: 0, sizeBytes: 10, magnetLink: "")
        var download = DownloadsViewModel.Download(torrent: torrent, status: .paused, destinationURL: root)
        download.contentRootURL = root
        #expect(DownloadsViewModel.downloadRemovalURL(for: download) == nil)
        download.destinationURL = root.appendingPathComponent("Original Torrent", isDirectory: true)
        #expect(DownloadsViewModel.downloadRemovalURL(for: download)?.path == "/tmp/Downloads/Original Torrent")
        download.destinationURL = root.appendingPathComponent(".TorrentScout", isDirectory: true)
            .appendingPathComponent(download.id.uuidString, isDirectory: true)
        #expect(DownloadsViewModel.downloadRemovalURL(for: download) == download.destinationURL?.standardizedFileURL)
        download.destinationURL = URL(fileURLWithPath: "/tmp/Other/content")
        #expect(DownloadsViewModel.downloadRemovalURL(for: download) == nil)
    }

    @Test func sharedDownloadLayoutSurvivesPersistenceAndLegacyState() throws {
        let torrent = TorrentItem(title: "Search title", seeders: 0, leechers: 0, sizeBytes: 10, magnetLink: "")
        var download = DownloadsViewModel.Download(torrent: torrent, progress: 0.5, status: .paused,
            destinationURL: URL(fileURLWithPath: "/tmp/Downloads/Original Torrent"),
            storageURL: URL(fileURLWithPath: "/tmp/Downloads"), downloadedBytes: 5)
        download.contentRootURL = download.storageURL
        let encoded = try JSONEncoder().encode(DownloadsViewModel.PersistedDownload(download: download))
        let decoded = try JSONDecoder().decode(DownloadsViewModel.PersistedDownload.self, from: encoded).makeDownload()
        #expect(decoded.contentRootURL == download.contentRootURL)
        #expect(decoded.destinationURL == download.destinationURL)
        #expect(decoded.storageURL == download.storageURL)
        #expect(decoded.progress == 0.5)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "contentRootURL")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let restored = try JSONDecoder().decode(DownloadsViewModel.PersistedDownload.self, from: legacyData).makeDownload()
        #expect(restored.contentRootURL == nil)
        #expect(restored.storageURL == download.storageURL)
    }

    @MainActor
    @Test func persistedDownloadRoundTripsStorageBookmarkAndSeedingIntent() throws {
        let torrent = TorrentItem(title: "Persisted", seeders: 1, leechers: 0,
                                  sizeBytes: 42,
                                  magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        var download = DownloadsViewModel.Download(torrent: torrent,
                                                   status: .paused,
                                                   averageSpeedBytesPerSec: 2_000_000,
                                                   peakSpeedBytesPerSec: 8_000_000,
                                                   destinationURL: URL(fileURLWithPath: "/tmp/Persisted"),
                                                   storageURL: URL(fileURLWithPath: "/tmp/Persisted"),
                                                   storageBookmark: Data([1, 2, 3]),
                                                   totalBytes: 42,
                                                   downloadedBytes: 17,
                                                   isSeeding: false)
        download.isSeedingDesired = true
        download.queuePriority = 1
        download.isForceStarted = true
        download.isSequentialDownload = true
        download.selectedFileIndices = [0, 2]
        download.files = [
            .init(relativePath: "one.bin", length: 10),
            .init(relativePath: "two.bin", length: 12),
            .init(relativePath: "three.bin", length: 20)
        ]
        download.filePriorities = [7, 0, 4]
        download.firstLastPiecePriority = true
        download.downloadLimitBytesPerSec = 5_000_000
        download.uploadLimitBytesPerSec = 1_000_000
        download.maxUploads = 8
        download.category = "Movies"
        download.tags = ["favorite", "4K"]
        download.shareRatioLimit = 2.5
        download.shareRatioAction = .pause
        download.seedingTimeLimitMinutes = 1440
        download.inactiveSeedingTimeLimitMinutes = 120
        download.seedingTimeSeconds = 900
        download.inactiveSeedingTimeSeconds = 50

        let snapshot = DownloadsViewModel.PersistedDownload(download: download)
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(DownloadsViewModel.PersistedDownload.self, from: data).makeDownload()

        #expect(restored.storageBookmark == Data([1, 2, 3]))
        #expect(restored.destinationURL == download.destinationURL)
        #expect(restored.storageURL == download.storageURL)
        #expect(restored.isSeeding == false)
        #expect(restored.isSeedingDesired == true)
        #expect(restored.status == .paused)
        #expect(restored.downloadedBytes == 17)
        #expect(restored.queuePriority == 1)
        #expect(restored.isForceStarted)
        #expect(restored.peakSpeedBytesPerSec == 8_000_000)
        #expect(restored.isSequentialDownload)
        #expect(restored.selectedFileIndices == [0, 2])
        #expect(restored.filePriorities == [7, 0, 4])
        #expect(restored.firstLastPiecePriority)
        #expect(restored.downloadLimitBytesPerSec == 5_000_000)
        #expect(restored.uploadLimitBytesPerSec == 1_000_000)
        #expect(restored.maxUploads == 8)
        #expect(restored.category == "Movies")
        #expect(restored.tags == ["4K", "favorite"])
        #expect(restored.shareRatioLimit == 2.5)
        #expect(restored.shareRatioAction == .pause)
        #expect(restored.seedingTimeLimitMinutes == 1440)
        #expect(restored.inactiveSeedingTimeLimitMinutes == 120)
        #expect(restored.seedingTimeSeconds == 900)
        #expect(restored.inactiveSeedingTimeSeconds == 50)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["seedingTimeLimitMinutes", "inactiveSeedingTimeLimitMinutes", "seedingTimeSeconds", "inactiveSeedingTimeSeconds"] {
            legacy.removeValue(forKey: key)
        }
        let old = try JSONDecoder().decode(DownloadsViewModel.PersistedDownload.self,
            from: JSONSerialization.data(withJSONObject: legacy)).makeDownload()
        #expect(old.seedingTimeLimitMinutes == nil)
        #expect(old.inactiveSeedingTimeLimitMinutes == nil)
        #expect(old.seedingTimeSeconds == 0)
        #expect(old.inactiveSeedingTimeSeconds == 0)
    }
}
