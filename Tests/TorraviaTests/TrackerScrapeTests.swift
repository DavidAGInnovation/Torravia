@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

@MainActor
struct TrackerScrapeTests {
    @Test func trackerScrapeParsesBinaryHashAndRejectsMissingOrMalformedCounts() throws {
        let hash = Data(repeating: 255, count: 20)
        var valid = Data("d5:filesd20:".utf8)
        valid.append(hash)
        valid.append(Data("d8:completei0e10:incompletei2eeee".utf8))
        let counts = try #require(TrackerPeerScraper.parseHTTPResponse(valid, hash: hash))
        #expect(counts.0 == 0 && counts.1 == 2)
        #expect(TrackerPeerScraper.parseHTTPResponse(valid, hash: Data(repeating: 254, count: 20)) == nil)
        #expect(TrackerPeerScraper.parseHTTPResponse(valid.dropLast(), hash: hash) == nil)
        #expect(TrackerPeerScraper.parseHTTPResponse(Data("<html>Online</html>".utf8), hash: hash) == nil)
        var negative = Data("d5:filesd20:".utf8)
        negative.append(hash)
        negative.append(Data("d8:completei-1e10:incompletei2eeee".utf8))
        #expect(TrackerPeerScraper.parseHTTPResponse(negative, hash: hash) == nil)
    }

    @Test func trackerScrapeRequestsBatchAndDeduplicateOnlyApprovedEndpoints() {
        let udp = "udp://public.example:80/announce"
        let http = "https://http.example/announce"
        let magnets = (1...130).map { "magnet:?xt=urn:btih:" + String(format: "%040x", $0) }
        let requests = TrackerPeerScraper.requests(magnets: magnets + [magnets[0], "magnet:?xt=urn:btih:bad"],
            fallback: [udp, http])
        let batches = requests.filter { $0.tracker.scheme == "udp" }
        #expect(batches.map { $0.hashes.count } == [64, 64, 2])
        #expect(Set(batches.flatMap(\.hashes)).count == 130)
        #expect(requests.filter { $0.tracker.scheme == "https" }.allSatisfy { $0.hashes.count == 1 })
        #expect(requests.count == 133)
        let privateMagnet = magnets[0] + "&tr=udp://private.example:80/announce"
        #expect(TrackerPeerScraper.requests(magnets: [privateMagnet], fallback: [udp]).isEmpty)
    }

    @Test func trackerScrapePreservesEncodedTrackersWithLiteralDisplayNameCharacters() async throws {
        let hash = "b5d49da6546c3ec73a2ecfd3ce0b63535c5ab6cc"
        let tracker = "udp://tracker.opentrackr.org:1337/announce"
        let encodedTracker = "udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"
        // The reported 1337x result mixes literal and escaped brackets.
        let magnet = "magnet:?xt=urn:btih:\(hash.uppercased())"
            + "&dn=[1337x.HashHackers.Com]%5BHorribleSubs%5D+Sword Art Online [1080p]"
            + "&tr=udp%3A%2F%2Fprivate.example%3A80%2Fannounce&tr=\(encodedTracker)"
        #expect(TrackerPeerScraper.infoHash(in: magnet) == hash)
        #expect(TrackerPeerScraper.trackers(in: magnet, fallback: [tracker]).map(\.absoluteString) == [tracker])
        let estimates = await TrackerPeerScraper.checkMany(magnets: [magnet], fallback: [tracker],
            scrape: { url, hashes in
                #expect(url.absoluteString == tracker)
                #expect(hashes == [TrackerPeerScraper.hashBytes(hash)!])
                return [TrackerPeerEstimate(seeders: 6, leechers: 0, checkedAt: Date(), tracker: url)]
            })
        let estimate = try #require(estimates[hash])
        let item = TorrentItem(title: "Sword Art Online", seeders: 640, leechers: 13, sizeBytes: 1, magnetLink: magnet)
        let state = SearchPeerCountState(estimate: estimate)
        #expect(state.seedersLabel(for: item) == "6 tracker seeders")
        #expect(state.leechersLabel(for: item) == "0 tracker leechers")
        let escaped = magnet.replacingOccurrences(of: "[", with: "%5B").replacingOccurrences(of: "]", with: "%5D")
            .replacingOccurrences(of: " ", with: "%20")
        #expect(TrackerPeerScraper.trackers(in: escaped, fallback: [tracker]).map(\.absoluteString) == [tracker])
        #expect(TrackerPeerScraper.infoHash(in: "magnet:?xt=urn%3Abtih%3A\(hash)&dn=[Title]") == hash)
        #expect(TrackerPeerScraper.trackers(in: "https://example.com/?dn=[Title]", fallback: [tracker]).isEmpty)
        #expect(TrackerPeerScraper.trackers(in: "magnet:?xt=urn:btih:\(hash)&dn=bad%ZZ", fallback: [tracker]).isEmpty)
    }

    @Test func trackerScrapeRecognizesPublicUDPAliasesWithoutApprovingPrivateURLs() async {
        let hash = String(repeating: "a", count: 40)
        let base = "magnet:?xt=urn:btih:\(hash)"
        let approved = ["udp://open.demonii.com:1337/announce", "udp://exodus.desync.com:6969/announce", "https://public.example/announce"]
        let bare = base + "&tr=udp://OPEN.DEMONII.COM:1337&tr=udp://exodus.desync.com:6969/"
        let requests = TrackerPeerScraper.requests(magnets: [bare], fallback: approved)
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.hashes == [hash] })
        let estimates = await TrackerPeerScraper.checkMany(magnets: [bare], fallback: approved,
            scrape: { tracker, _ in [TrackerPeerEstimate(seeders: 8, leechers: 1, checkedAt: Date(), tracker: tracker)] })
        #expect(estimates[hash]?.seeders == 8)
        let privateURLs = ["udp://open.demonii.com:1337/private", "udp://open.demonii.com:1337?passkey=secret",
                           "udp://user:secret@open.demonii.com:1337", "udp://unapproved.example:1337",
                           "https://public.example/Announce", "https://public.example/announce?passkey=secret"]
        for tracker in privateURLs {
            let components = base + "&tr=" + tracker.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            #expect(TrackerPeerScraper.trackers(in: components, fallback: approved).isEmpty)
        }
        #expect(TrackerPeerScraper.trackers(in: base + "&tr=https://public.example:443/announce", fallback: approved).count == 1)
    }

    @Test func batchedTrackerEstimatesKeepHashOrderAndTakeMaximumWithoutAdding() async {
        let magnets = ["a", "b"].map { "magnet:?xt=urn:btih:" + String(repeating: $0, count: 40) }
        let counts = await TrackerPeerScraper.checkMany(magnets: magnets,
            fallback: ["udp://first.example:80/announce", "udp://second.example:80/announce"],
            scrape: { tracker, hashes in
                hashes.enumerated().map { index, _ in
                    let seeds = tracker.host == "first.example" ? [4, 0][index] : [17, 2][index]
                    return TrackerPeerEstimate(seeders: seeds, leechers: index,
                        checkedAt: Date(), tracker: tracker)
                }
            })
        #expect(counts[String(repeating: "a", count: 40)]?.seeders == 17)
        #expect(counts[String(repeating: "b", count: 40)]?.seeders == 2)
        let incomplete = await TrackerPeerScraper.checkMany(magnets: magnets,
            fallback: ["udp://first.example:80/announce"], scrape: { _, _ in [] })
        #expect(incomplete.isEmpty)
    }

    @Test func batchedScrapesLimitConcurrentRequestsAndHonorCancellation() async {
        let lookup = ControlledPeerLookup()
        let magnets = (1...10).map { "magnet:?xt=urn:btih:" + String(format: "%040x", $0) }
        let batch = Task {
            await TrackerPeerScraper.checkMany(magnets: magnets,
                fallback: ["https://public.example/announce"], concurrency: 2,
                scrape: { tracker, hashes in
                    let estimate = await lookup.lookup(tracker.absoluteString)
                    return hashes.map { _ in estimate }
                })
        }
        await lookup.waitForCalls(2)
        #expect(await lookup.calls == 2)
        batch.cancel()
        await lookup.completeAll(TrackerPeerEstimate(seeders: 100, leechers: 0,
            checkedAt: Date(), tracker: URL(string: "https://public.example/announce")!))
        #expect(await batch.value.isEmpty)
        #expect(await lookup.calls == 2)
    }

    @Test func udpScrapeBatchParsesEveryCountAndRejectsWrongLengths() throws {
        let response = Data([0,0,0,2, 0,0,0,7,
            0,0,0,0, 0,0,0,50, 0,0,0,3,
            0,0,0,17, 0,0,0,1, 0,0,0,2])
        let counts = try #require(UDPTrackerScrape.parseResponses(response, transaction: 7, count: 2))
        #expect(counts.count == 2)
        #expect(counts[0].0 == 0 && counts[0].1 == 3)
        #expect(counts[1].0 == 17 && counts[1].1 == 2)
        #expect(UDPTrackerScrape.parseResponses(response, transaction: 7, count: 1) == nil)
        #expect(UDPTrackerScrape.parseResponses(response.dropLast(), transaction: 7, count: 2) == nil)
        #expect(UDPTrackerScrape.parseResponses(response, transaction: 8, count: 2) == nil)
        #expect(UDPTrackerScrape.parseResponses(response, transaction: 7, count: 0) == nil)
        #expect(UDPTrackerScrape.parseResponses(response, transaction: 7, count: 65) == nil)
    }

    @Test func udpScrapeRejectsWrongTransactionsErrorsAndTruncation() throws {
        let response = Data([0,0,0,2, 0,0,0,7, 0,0,0,0, 0,0,0,50, 0,0,0,3])
        let counts = try #require(UDPTrackerScrape.parseResponse(response, transaction: 7))
        #expect(counts.0 == 0 && counts.1 == 3)
        #expect(UDPTrackerScrape.parseResponse(response, transaction: 8) == nil)
        #expect(UDPTrackerScrape.parseResponse(response.dropLast(), transaction: 7) == nil)
        var error = response
        error[3] = 3
        #expect(UDPTrackerScrape.parseResponse(error, transaction: 7) == nil)
    }

    @Test func scrapeURLsUseBinaryHashesAndPreserveTrackerTokens() throws {
        let hash = Data(repeating: 255, count: 20)
        let url = try #require(TrackerPeerScraper.scrapeURL(tracker: URL(string: "https://tracker.example/path/announce.php?token=abc")!, hash: hash))
        #expect(url.path == "/path/scrape.php")
        #expect(url.absoluteString.contains("token=abc&info_hash=" + String(repeating: "%FF", count: 20)))
        #expect(TrackerPeerScraper.scrapeURL(tracker: URL(string: "https://tracker.example/api")!, hash: hash) == nil)
        #expect(TrackerPeerScraper.infoHash(in: "magnet:?xt=urn:btih:" + String(repeating: "A", count: 32)) == String(repeating: "0", count: 40))
        #expect(TrackerPeerScraper.infoHash(in: "magnet:?xt=urn:btih:bad") == nil)
        let magnet = "magnet:?xt=urn:btih:" + String(repeating: "0", count: 40) + "&tr=udp://private.example:80/announce&tr=udp://public.example:80/announce"
        #expect(TrackerPeerScraper.trackers(in: magnet, fallback: ["udp://public.example:80/announce"]).map(\.host) == ["public.example"])
    }

    @Test func publishedOpenTrackrUDPRemainsApprovedAlongsideHTTPListEntry() {
        let magnet = "magnet:?xt=urn:btih:fb8e884242c26e60f38dedf17b37327bdcffb1d6&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"
        let approved = TrackerPeerScraper.trackers(in: magnet, fallback: TrackerPeerScraper.approvedPublicTrackers)
        #expect(approved.map(\.absoluteString) == [TrackerPeerScraper.openTrackrUDP])
        let privateMagnet = magnet + "%3Fpasskey%3Dprivate"
        #expect(TrackerPeerScraper.trackers(in: privateMagnet, fallback: TrackerPeerScraper.approvedPublicTrackers).isEmpty)
    }
}
