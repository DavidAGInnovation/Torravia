@testable import TorraviaSearchCore
import Foundation
import CryptoKit
import Testing
@testable import Torravia

@MainActor
struct TorrentCreatorTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func info(_ result: CreatedTorrent) throws -> [String: Bencode] {
        guard case .dictionary(let root) = try Bencode.decode(data: result.data),
              case .dictionary(let info) = root["info"] else { throw BencodeError.invalidFormat }
        return info
    }
    private func hashes(_ payload: Data, pieceLength: Int) -> Data {
        var output = Data()
        for offset in stride(from: 0, to: payload.count, by: pieceLength) {
            output.append(contentsOf: Insecure.SHA1.hash(data: payload[offset..<min(offset + pieceLength, payload.count)]))
        }
        return output
    }

    @Test func singleFileIncludesVerifiedPiecesAndPrivateTrackerMetadata() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sample.bin")
        let payload = Data((0..<40_123).map { UInt8($0 % 251) })
        try payload.write(to: source)
        let result = try TorrentCreator.create(source: source, options: .init(
            format: .v1, trackers: ["http://127.0.0.1:9000/announce", "udp://localhost:9001/announce"],
            comment: "Test", isPrivate: true, pieceLength: 16_384))
        let metadata = try info(result)
        #expect(metadata["length"] == .integer(payload.count))
        #expect(metadata["pieces"] == .string(hashes(payload, pieceLength: 16_384)))
        #expect(metadata["private"] == .integer(1))
        #expect(result.fileCount == 1)
        let independentHash = Insecure.SHA1.hash(data: Bencode.dictionary(metadata).encode()).map { String(format: "%02x", $0) }.joined()
        #expect(result.infoHash == independentHash)
        let summary = try #require(try DownloadsViewModel.parseTorrentFile(data: result.data))
        #expect(summary.infoHash == result.infoHash)
        #expect(summary.totalSize == Int64(payload.count))
        #expect(summary.trackerURLs.count == 2)
    }

    @Test func folderHashesAcrossFileBoundariesAndKeepsEmptyFiles() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = Data(repeating: 0x12, count: 10_000), second = Data(repeating: 0x34, count: 24_000)
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try second.write(to: nested.appendingPathComponent("b.bin"))
        try first.write(to: folder.appendingPathComponent("a.bin"))
        try Data().write(to: folder.appendingPathComponent("empty.bin"))
        let result = try TorrentCreator.create(source: folder, options: .init(format: .v1, pieceLength: 16_384))
        let metadata = try info(result)
        #expect(metadata["length"] == nil)
        #expect(metadata["pieces"] == .string(hashes(first + second, pieceLength: 16_384)))
        #expect(metadata["files"] == .list([
            .dictionary(["length": .integer(10_000), "path": .list([.string(Data("a.bin".utf8))])]),
            .dictionary(["length": .integer(0), "path": .list([.string(Data("empty.bin".utf8))])]),
            .dictionary(["length": .integer(24_000), "path": .list([.string(Data("nested".utf8)), .string(Data("b.bin".utf8))])])
        ]))
        #expect(result.totalBytes == 34_000)
        #expect(result.fileCount == 3)
    }

    @Test(arguments: TorrentFormat.allCases)
    func formatsHaveCorrectIdentityAndPreserveBinaryHashKeys(format: TorrentFormat) throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("sample.bin")
        let payload = Data(repeating: 42, count: 40_123)
        try payload.write(to: source)
        let result = try TorrentCreator.create(source: source, options: .init(format: format, pieceLength: 16_384))
        let metadata = try info(result)
        let summary = try #require(try DownloadsViewModel.parseTorrentFile(data: result.data))
        #expect((metadata["pieces"] != nil) == (format != .v2))
        #expect((metadata["meta version"] == .integer(2)) == (format != .v1))
        #expect((summary.infoHash != nil) == (format != .v2))
        #expect((summary.v2InfoHash != nil) == (format != .v1))
        #expect(summary.infoHash ?? summary.v2InfoHash == result.infoHash)
        #expect(summary.totalSize == Int64(payload.count))
        #expect(try Bencode.decode(data: result.data).encode() == result.data)
        if let hash = summary.v2InfoHash {
            let independent = SHA256.hash(data: Bencode.dictionary(metadata).encode()).map { String(format: "%02x", $0) }.joined()
            #expect(hash == independent)
        }
    }

    @Test func hybridIsDefaultAndPaddingDoesNotCountAsSourceContent() throws {
        #expect(TorrentCreationOptions().format == .hybrid)
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: source.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 24_000).write(to: source.appendingPathComponent("b.bin"))
        let result = try TorrentCreator.create(source: source, options: .init(pieceLength: 16_384))
        let summary = try #require(try DownloadsViewModel.parseTorrentFile(data: result.data))
        #expect(summary.fileCount == 2 && summary.totalSize == 34_000)
        let download = try DownloadsViewModel.originalSeedDownload(data: result.data, fileName: "share.torrent", source: source, bookmark: nil)
        #expect(download.files.map(\.relativePath) == ["Shared/a.bin", "Shared/b.bin"])
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent(".pad").path))
    }

    @Test func binaryDictionaryRoundTripDoesNotLoseHashKeys() throws {
        let value = Bencode.binaryDictionary([Data([0xff, 0x00]): .string(Data([1])), Data([0xfe, 0x00]): .string(Data([2]))])
        #expect(try Bencode.decode(data: value.encode()) == value)
    }

    @Test func rejectsInvalidOptionsAndSymlinks() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.bin")
        try Data("sample".utf8).write(to: source)
        #expect(throws: TorrentCreationError.self) { try TorrentCreator.create(source: source, options: .init(isPrivate: true)) }
        #expect(throws: TorrentCreationError.self) { try TorrentCreator.create(source: source, options: .init(pieceLength: 17_000)) }
        #expect(throws: TorrentCreationError.self) { try TorrentCreator.create(source: source, options: .init(trackers: ["file:///tmp/tracker"])) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: source)
        #expect(throws: TorrentCreationError.self) { try TorrentCreator.create(source: folder, options: .init()) }
    }

    @Test(arguments: ["torrent", "TORRENT"])
    func rejectsTorrentMetadataAsDirectSource(fileExtension: String) throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.bin")
        try Data("Original content".utf8).write(to: source)
        let torrent = try TorrentCreator.create(source: source, options: .init())
        let metadata = folder.appendingPathComponent("original.bin.\(fileExtension)")
        try torrent.data.write(to: metadata)
        do {
            _ = try TorrentCreator.create(source: metadata, options: .init())
            Issue.record("Creating a torrent from torrent metadata should be rejected")
        } catch TorrentCreationError.torrentMetadataSource {}
        #expect(try Data(contentsOf: metadata) == torrent.data)
    }

    @Test func folderWithTorrentExtensionStillIncludesAllItsFiles() throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Shared.torrent")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("Source content".utf8).write(to: source.appendingPathComponent("sample.bin"))
        // This restriction is only for the directly selected file, not a filter
        // that silently removes files from a selected folder's content.
        try Data("Included metadata".utf8).write(to: source.appendingPathComponent("nested.torrent"))
        let torrent = try TorrentCreator.create(source: source, options: .init())
        #expect(torrent.fileCount == 2)
    }

    @Test func detectsSourceGrowthWhileHashing() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sample.bin")
        try Data(repeating: 1, count: 32_768).write(to: source)
        #expect(throws: TorrentCreationError.self) {
            try TorrentCreator.create(source: source, options: .init(pieceLength: 16_384)) { _ in
                if let handle = try? FileHandle(forWritingTo: source) {
                    try? handle.seekToEnd(); try? handle.write(contentsOf: Data([2])); try? handle.close()
                }
            }
        }
    }
}
