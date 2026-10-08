@testable import TorraviaSearchCore
import Foundation
import Testing
@testable import Torravia

@MainActor
struct OriginalSeedingTests {
    private func fixture() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent
    }

    @Test(arguments: [false, true], TorrentFormat.allCases)
    func remembersOriginalContentAcrossStoreReloadsByTorrentIdentity(isFolder: Bool, format: TorrentFormat) throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent(isFolder ? "Shared Folder" : "sample.bin")
        if isFolder { try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true) }
        let content = isFolder ? source.appendingPathComponent("sample.bin") : source
        try Data(repeating: 42, count: 32_000).write(to: content)
        let result = try TorrentCreator.create(source: source, options: .init(format: format))
        let stateURL = parent.appendingPathComponent("State/original-content.json")
        try TorrentSourceStore(url: stateURL).remember(data: result.data, source: source)
        let restored = TorrentSourceStore(url: stateURL)
        #expect(try restored.source(for: result.data)?.path == source.path)
        // Changing outer metadata does not lose the association; the info hash is unchanged.
        guard case .dictionary(var root) = try Bencode.decode(data: result.data) else { throw BencodeError.invalidFormat }
        root["comment"] = .string(Data("Updated comment".utf8))
        #expect(try restored.source(for: Bencode.dictionary(root).encode())?.path == source.path)
        // A different torrent with the same name must not inherit this location.
        try Data(repeating: 43, count: 32_000).write(to: content)
        let other = try TorrentCreator.create(source: source, options: .init(format: format))
        #expect(try restored.source(for: other.data) == nil)
        try Data([1]).write(to: content)
        #expect(throws: OriginalSeedingError.self) { try restored.source(for: result.data) }
    }

    @Test func corruptSourceHistoryIsPreservedAndUnknownTorrentsHaveNoAutomaticSource() throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("sample.bin")
        try Data(repeating: 7, count: 16_384).write(to: source)
        let torrent = try TorrentCreator.create(source: source, options: .init())
        let stateURL = parent.appendingPathComponent("original-content.json")
        let store = TorrentSourceStore(url: stateURL)
        #expect(try store.source(for: torrent.data) == nil)
        let corrupt = Data("broken history".utf8)
        try corrupt.write(to: stateURL)
        #expect(throws: DecodingError.self) { try store.remember(data: torrent.data, source: source) }
        #expect(try Data(contentsOf: stateURL) == corrupt)
    }

    @Test func createdFolderSeedsInPlaceAndPersistsOwnership() throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Originals/nested")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 40_000).write(to: source.appendingPathComponent("sample.bin"))
        try Data().write(to: source.appendingPathComponent("empty.bin"))
        let result = try TorrentCreator.create(source: source.deletingLastPathComponent(), options: .init())
        let download = try DownloadsViewModel.originalSeedDownload(data: result.data,
            fileName: "share.torrent", source: source.deletingLastPathComponent(), bookmark: Data([1, 2]))
        #expect(download.isSeedOnly && download.isSeedingDesired && !download.isSeeding)
        #expect(download.storageURL?.path == parent.path)
        #expect(download.destinationURL?.path == source.deletingLastPathComponent().path)
        #expect(download.files.map(\.relativePath) == ["Originals/nested/empty.bin", "Originals/nested/sample.bin"])
        #expect(download.infoHash == result.infoHash)
        #expect(download.status == .queued && download.progress == 0)
        #expect(DownloadsViewModel.downloadRemovalURL(for: download) == nil)
        let encoded = try JSONEncoder().encode(DownloadsViewModel.PersistedDownload(download: download))
        let restored = try JSONDecoder().decode(DownloadsViewModel.PersistedDownload.self, from: encoded).makeDownload()
        #expect(restored.isSeedOnly && restored.isSeedingDesired)
        #expect(restored.storageBookmark == Data([1, 2]))
        #expect(DownloadsViewModel.downloadRemovalURL(for: restored) == nil)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "isSeedOnly")
        let legacyDownload = try JSONDecoder().decode(DownloadsViewModel.PersistedDownload.self,
            from: JSONSerialization.data(withJSONObject: legacy)).makeDownload()
        #expect(!legacyDownload.isSeedOnly)
    }

    @Test func rejectsWrongSourceTypeAndChangedFiles() throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("sample.bin")
        try Data(repeating: 3, count: 16_384).write(to: source)
        let result = try TorrentCreator.create(source: source, options: .init())
        let wrong = parent.appendingPathComponent("wrong")
        try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: true)
        #expect(throws: OriginalSeedingError.self) {
            try DownloadsViewModel.originalSeedDownload(data: result.data, fileName: "sample.torrent", source: wrong, bookmark: nil)
        }
        try Data([3]).write(to: source)
        #expect(throws: OriginalSeedingError.self) {
            try DownloadsViewModel.originalSeedDownload(data: result.data, fileName: "sample.torrent", source: source, bookmark: nil)
        }
    }

    @Test(arguments: [false, true])
    func mismatchedContentReportsTorrentNameAndSelectedName(isFolder: Bool) throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let original = parent.appendingPathComponent(isFolder ? "Original Folder" : "0_2.webp")
        if isFolder { try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true) }
        let payload = isFolder ? original.appendingPathComponent("0_2.webp") : original
        try Data(repeating: 42, count: 32_000).write(to: payload)
        let torrent = try TorrentCreator.create(source: original, options: .init())
        let selected = parent.appendingPathComponent(isFolder ? "Renamed Folder" : "image.png")
        try FileManager.default.moveItem(at: original, to: selected)
        let selectedPayload = isFolder ? selected.appendingPathComponent("0_2.webp") : selected
        try Data(repeating: 7, count: 123).write(to: selectedPayload)
        do {
            _ = try DownloadsViewModel.originalSeedDownload(data: torrent.data,
                fileName: "share.torrent", source: selected, bookmark: nil)
            Issue.record("Mismatched content was accepted")
        } catch OriginalSeedingError.fileSizeMismatch(let expectedFile, let selectedFile, let expectedBytes, let actualBytes) {
            #expect(expectedFile == (isFolder ? "Original Folder/0_2.webp" : "0_2.webp"))
            #expect(selectedFile == (isFolder ? "Renamed Folder/0_2.webp" : "image.png"))
            #expect(expectedBytes == 32_000 && actualBytes == 123)
        }
        if isFolder {
            try FileManager.default.removeItem(at: selectedPayload)
            do {
                _ = try DownloadsViewModel.originalSeedDownload(data: torrent.data,
                    fileName: "share.torrent", source: selected, bookmark: nil)
                Issue.record("Missing content was accepted")
            } catch OriginalSeedingError.incompleteFolder(let expectedFile) {
                #expect(expectedFile == "Original Folder/0_2.webp")
            }
        }
    }

    @Test(arguments: [false, true], TorrentFormat.allCases)
    func selectedFileOrFolderCanBeRenamedWithoutMovingContent(isFolder: Bool, format: TorrentFormat) throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let original = parent.appendingPathComponent(isFolder ? "Original Folder" : "original.bin")
        let payload = Data(repeating: 42, count: 32_000)
        if isFolder {
            try FileManager.default.createDirectory(at: original.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try payload.write(to: original.appendingPathComponent("nested/file.bin"))
        } else { try payload.write(to: original) }
        let result = try TorrentCreator.create(source: original, options: .init(format: format))
        let selected = parent.appendingPathComponent(isFolder ? "Renamed Folder" : "renamed.bin")
        try FileManager.default.moveItem(at: original, to: selected)
        let bookmark = try selected.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        let download = try DownloadsViewModel.originalSeedDownload(data: result.data,
            fileName: "share.torrent", source: selected, bookmark: bookmark)
        #expect(download.destinationURL?.path == selected.path)
        #expect(download.storageURL?.path == parent.path)
        #expect(download.files.map(\.relativePath) == [isFolder ? "Renamed Folder/nested/file.bin" : "renamed.bin"])
        #expect(download.title == original.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        let content = isFolder ? selected.appendingPathComponent("nested/file.bin") : selected
        #expect(try Data(contentsOf: content) == payload)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: try #require(download.storageBookmark),
            options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #expect(resolved.path == selected.path)
    }

    @Test func containingFolderResolvesOnlyTheOriginalSingleFileAndKeepsFolderAccess() throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("sample.bin")
        let payload = Data(repeating: 42, count: 32_000)
        try payload.write(to: source)
        try payload.write(to: parent.appendingPathComponent("unrelated.bin"))
        let result = try TorrentCreator.create(source: source, options: .init())
        let bookmark = try parent.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        let download = try DownloadsViewModel.originalSeedDownload(data: result.data,
            fileName: "share.torrent", source: parent, bookmark: bookmark)
        #expect(download.destinationURL?.path == source.path)
        #expect(download.storageURL?.path == parent.path)
        #expect(download.files.map(\.relativePath) == ["sample.bin"])
        let restored = DownloadsViewModel.PersistedDownload(download: download).makeDownload()
        var stale = false
        let resolved = try URL(resolvingBookmarkData: try #require(restored.storageBookmark),
            options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #expect(resolved.path == parent.path)
        try FileManager.default.removeItem(at: source)
        #expect(throws: OriginalSeedingError.self) {
            try DownloadsViewModel.originalSeedDownload(data: result.data,
                fileName: "share.torrent", source: parent, bookmark: bookmark)
        }
        try FileManager.default.createSymbolicLink(at: source,
            withDestinationURL: parent.appendingPathComponent("unrelated.bin"))
        #expect(throws: OriginalSeedingError.self) {
            try DownloadsViewModel.originalSeedDownload(data: result.data,
                fileName: "share.torrent", source: parent, bookmark: bookmark)
        }
    }

    @Test func rejectsPathTraversalAndSymlinkedOriginals() throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("sample.bin")
        try Data(repeating: 5, count: 16_384).write(to: source)
        let result = try TorrentCreator.create(source: source, options: .init())
        guard case .dictionary(var root) = try Bencode.decode(data: result.data),
              case .dictionary(var info) = root["info"] else { throw BencodeError.invalidFormat }
        info["name"] = .string(Data("../sample.bin".utf8)); root["info"] = .dictionary(info)
        #expect(throws: OriginalSeedingError.self) {
            try DownloadsViewModel.originalSeedDownload(data: Bencode.dictionary(root).encode(),
                fileName: "sample.torrent", source: source, bookmark: nil)
        }
        let moved = parent.appendingPathComponent("moved.bin")
        try FileManager.default.moveItem(at: source, to: moved)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)
        #expect(throws: OriginalSeedingError.self) {
            try DownloadsViewModel.originalSeedDownload(data: result.data, fileName: "sample.torrent", source: source, bookmark: nil)
        }
    }

    @Test func verifiedManualSeedOverridesAutomaticPreferenceAndRemovalKeepsOriginal() async throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("sample.bin")
        let payload = Data(repeating: 5, count: 16_384)
        try payload.write(to: source)
        let result = try TorrentCreator.create(source: source, options: .init())
        let download = try DownloadsViewModel.originalSeedDownload(data: result.data,
            fileName: "sample.torrent", source: source, bookmark: nil)
        let suite = "OriginalSeedingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SeedingPreferencesStore(userDefaults: defaults)
        preferences.isSeedingEnabled = false
        let model = DownloadsViewModel(session: WebTorrentSession(), preferences: preferences,
            downloadLocation: DownloadLocationStore(userDefaults: defaults),
            persistenceURL: parent.appendingPathComponent("state.json"), startServices: false)
        model.replaceDownloads([download])
        await model.handle(sessionEvent: .done(.init(id: download.id.uuidString, path: parent,
            files: [.init(name: "sample.bin", length: Int64(payload.count))])))
        let completed = try #require(model.downloads.first)
        #expect(completed.status == .completed && completed.isSeeding && completed.isSeedingDesired)
        // Re-import must not downgrade ownership to a normal, deletable download.
        model.stopSeeding(completed)
        #expect(!model.add(from: download.torrent, torrentData: result.data))
        model.cancel(completed, deleteFiles: true)
        #expect(model.downloads.isEmpty)
        #expect(try Data(contentsOf: source) == payload)
    }

    @Test func hybridCompletionIgnoresVirtualPaddingAndPersistsItsFlag() async throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("sample.bin")
        let payload = Data(repeating: 5, count: 10_000)
        try payload.write(to: source)
        let result = try TorrentCreator.create(source: source, options: .init(pieceLength: 16_384))
        let download = try DownloadsViewModel.originalSeedDownload(data: result.data,
            fileName: "sample.torrent", source: source, bookmark: nil)
        let suite = "HybridCompletionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DownloadsViewModel(session: WebTorrentSession(),
            preferences: SeedingPreferencesStore(userDefaults: defaults),
            downloadLocation: DownloadLocationStore(userDefaults: defaults),
            persistenceURL: parent.appendingPathComponent("state.json"), startServices: false)
        model.replaceDownloads([download])
        await model.handle(sessionEvent: .done(.init(id: download.id.uuidString, path: parent,
            files: [.init(name: "sample.bin", length: 10_000),
                    .init(name: ".pad/6384", length: 6384, isPadding: true)])))
        let completed = try #require(model.downloads.first)
        #expect(completed.status == .completed && completed.isSeeding)
        #expect(completed.destinationURL?.path == source.path)
        #expect(completed.files.last?.isPadding == true)
        let encoded = try JSONEncoder().encode(DownloadsViewModel.PersistedDownload(download: completed))
        let restored = try JSONDecoder().decode(DownloadsViewModel.PersistedDownload.self, from: encoded).makeDownload()
        #expect(restored.files.last?.isPadding == true)
        #expect(DownloadsViewModel.completedFilesValidationFailure(restored.files, in: parent) == nil)
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent(".pad").path))
    }
}
