@testable import TorraviaSearchCore
import Foundation
import Testing
@testable import Torravia

@MainActor
struct TorrentMetadataEditorTests {
    private func fixture(format: TorrentFormat) throws -> CreatedTorrent {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.bin")
        try Data(repeating: 42, count: 40_123).write(to: source)
        return try TorrentCreator.create(source: source, options: .init(format: format,
            trackers: ["https://tracker.example/announce"], comment: "Original comment", pieceLength: 16_384))
    }

    @Test(arguments: TorrentFormat.allCases)
    func restoresSettingsAndEditsSharingMetadataWithoutOriginals(format: TorrentFormat) throws {
        let created = try fixture(format: format)
        guard case .dictionary(var root) = try Bencode.decode(data: created.data) else {
            Issue.record("Expected a torrent dictionary"); return
        }
        let tiers: Bencode = .list([.list([.string(Data("https://tracker.example/announce".utf8)),
                                        .string(Data("https://backup.example/announce".utf8))])])
        root["announce-list"] = tiers
        root["url-list"] = .string(Data("https://seed.example/original.bin".utf8))
        root["custom"] = .string(Data([0, 1, 255]))
        let data = Bencode.dictionary(root).encode()
        let loaded = try TorrentMetadataEditor.read(data: data)
        #expect(loaded.options.format == format)
        #expect(loaded.options.pieceLength == 16_384)
        #expect(loaded.options.comment == "Original comment")
        #expect(loaded.options.trackers.count == 2)
        var options = loaded.options
        options.comment = "Edited without original content"
        let updated = try TorrentMetadataEditor.update(data: data, options: options)
        guard case .dictionary(let edited) = try Bencode.decode(data: updated.data) else {
            Issue.record("Expected edited metadata"); return
        }
        #expect(edited["info"] == root["info"])
        #expect(updated.v1InfoHash == created.v1InfoHash)
        #expect(updated.v2InfoHash == created.v2InfoHash)
        #expect(edited["announce-list"] == tiers)
        #expect(edited["url-list"] == root["url-list"])
        #expect(edited["custom"] == root["custom"])
        #expect(edited["piece layers"] == root["piece layers"])
        #expect(try TorrentMetadataEditor.read(data: updated.data).options.comment == options.comment)
    }

    @Test func trackerAndPrivacyEditsValidateAndChangeIdentityWhenRequired() throws {
        let created = try fixture(format: .hybrid)
        var options = try TorrentMetadataEditor.read(data: created.data).options
        options.trackers = ["udp://tracker.example:80/announce"]
        let trackerEdit = try TorrentMetadataEditor.update(data: created.data, options: options)
        #expect(trackerEdit.infoHash == created.infoHash)
        #expect(try TorrentMetadataEditor.read(data: trackerEdit.data).options.trackers == options.trackers)
        options.isPrivate = true
        let privateEdit = try TorrentMetadataEditor.update(data: trackerEdit.data, options: options)
        #expect(privateEdit.v1InfoHash != created.v1InfoHash)
        #expect(privateEdit.v2InfoHash != created.v2InfoHash)
        #expect(try TorrentMetadataEditor.read(data: privateEdit.data).options.isPrivate)
        options.trackers = []
        #expect(throws: TorrentCreationError.self) {
            try TorrentMetadataEditor.update(data: privateEdit.data, options: options)
        }
    }

    @Test func contentSettingsRequireRecreationAndMalformedFilesAreRejected() throws {
        let created = try fixture(format: .v1)
        var options = try TorrentMetadataEditor.read(data: created.data).options
        options.format = .v2
        #expect(throws: TorrentCreationError.self) {
            try TorrentMetadataEditor.update(data: created.data, options: options)
        }
        #expect(throws: (any Error).self) {
            try TorrentMetadataEditor.read(data: Data("d4:infoi1ee".utf8))
        }
    }

    @Test func onlyValidCreationPreferencesAreRestored() {
        let name = "TorrentCreatorPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(TorrentCreationPreferences.format(in: defaults) == .hybrid)
        #expect(TorrentCreationPreferences.pieceLength(in: defaults) == 0)
        defaults.set("v2", forKey: TorrentCreationPreferences.formatKey)
        defaults.set(32_768, forKey: TorrentCreationPreferences.pieceLengthKey)
        #expect(TorrentCreationPreferences.format(in: defaults) == .v2)
        #expect(TorrentCreationPreferences.pieceLength(in: defaults) == 32_768)
        defaults.set("unsupported", forKey: TorrentCreationPreferences.formatKey)
        defaults.set(-1, forKey: TorrentCreationPreferences.pieceLengthKey)
        #expect(TorrentCreationPreferences.format(in: defaults) == .hybrid)
        #expect(TorrentCreationPreferences.pieceLength(in: defaults) == 0)
    }
}
