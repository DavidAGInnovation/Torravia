@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

@MainActor
struct TorrentMetadataTests {
    @Test func bencodeRejectsMalformedAndOverflowingValues() throws {
        for raw in [
            "i01e", "i-0e", "i9223372036854775808e", "i-9223372036854775809e",
            "01:a", "1", "999999999999999999999999999:"
        ] {
            do {
                _ = try Bencode.decode(data: Data(raw.utf8))
                Issue.record("Expected malformed bencode to be rejected: \(raw)")
            } catch {
                // Expected.
            }
        }
    }

    @Test func parsesV1AndV2TorrentMetadata() throws {
        let v1Info = Bencode.dictionary([
            "name": .string(Data("v1".utf8)),
            "length": .integer(12),
            "pieces": .string(Data(repeating: 0, count: 20))
        ])
        let v1Data = Bencode.dictionary(["info": v1Info]).encode()
        let v1SummaryValue = try DownloadsViewModel.parseTorrentFile(data: v1Data)
        let v1Summary = try #require(v1SummaryValue)
        #expect(v1Summary.infoHash != nil)
        #expect(v1Summary.v2InfoHash == nil)
        #expect(v1Summary.magnetLink?.contains("urn:btih:") == true)

        let trackerInfo = Bencode.dictionary([
            "announce": .string(Data("udp://tracker.one:1337/announce".utf8)),
            "announce-list": .list([
                .list([.string(Data("udp://tracker.one:1337/announce".utf8))]),
                .list([.string(Data("https://tracker.two/announce".utf8))])
            ]),
            "info": v1Info
        ])
        let trackerSummary = try #require(try DownloadsViewModel.parseTorrentFile(data: trackerInfo.encode()))
        #expect(trackerSummary.trackerURLs == [
            "udp://tracker.one:1337/announce",
            "https://tracker.two/announce"
        ])
        #expect(trackerSummary.magnetLink?.contains("tracker.one") == true)
        #expect(trackerSummary.magnetLink?.contains("tracker.two") == true)

        let v2Info = Bencode.dictionary([
            "name": .string(Data("v2".utf8)),
            "meta version": .integer(2),
            "file tree": .dictionary([
                "file.bin": .dictionary([
                    "": .dictionary(["length": .integer(24)])
                ])
            ])
        ])
        let v2Data = Bencode.dictionary(["info": v2Info]).encode()
        let v2SummaryValue = try DownloadsViewModel.parseTorrentFile(data: v2Data)
        let v2Summary = try #require(v2SummaryValue)
        #expect(v2Summary.infoHash == nil)
        #expect(v2Summary.v2InfoHash?.count == 64)
        #expect(v2Summary.totalSize == 24)
        #expect(v2Summary.fileCount == 1)
        #expect(v2Summary.magnetLink?.contains("urn:btmh:1220") == true)
    }
}
