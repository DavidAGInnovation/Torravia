@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

@MainActor
struct PeerCountTests {
    @Test func seederSortFollowsDisplayedCountsAsEstimatesArrive() {
        let items = [9000, 8000, 7000, 100].enumerated().map { index, seeds in
            TorrentItem(title: "Result \(index)", seeders: seeds, leechers: 0, sizeBytes: 1,
                magnetLink: "magnet:?xt=urn:btih:" + String(repeating: String(index), count: 40))
        }
        let hashes = items.map { TrackerPeerScraper.infoHash(in: $0.magnetLink)! }
        func state(_ seeds: Int) -> SearchPeerCountState {
            SearchPeerCountState(estimate: TrackerPeerEstimate(seeders: seeds, leechers: 0,
                checkedAt: Date(), tracker: URL(string: "udp://tracker.example:80/announce")!))
        }
        var states = [hashes[0]: state(4), hashes[1]: state(0), hashes[2]: state(2), hashes[3]: state(17)]
        #expect(SearchResultsSortOrder.seeders.sorted(items, peerStates: states).map(\.id)
            == [items[3], items[0], items[2], items[1]].map(\.id))
        states[hashes[1]] = state(30)
        #expect(SearchResultsSortOrder.seeders.sorted(items, peerStates: states).first?.id == items[1].id)
        // Pending and failed checks stay unknown, regardless of indexed counts.
        states[hashes[0]] = SearchPeerCountState(isChecking: true)
        states[hashes[2]] = SearchPeerCountState(checkedAt: Date())
        #expect(SearchResultsSortOrder.seeders.sorted(items, peerStates: states).map(\.id)
            == [items[1], items[3], items[0], items[2]].map(\.id))
        states[hashes[1]] = state(0)
        #expect(SearchResultsSortOrder.seeders.sorted(items, peerStates: states).map(\.id)
            == [items[3], items[1], items[0], items[2]].map(\.id))
    }

    @Test func sizeSortingKeepsUnknownSizesLastAndUsesDisplayedCountsForTies() {
        let first = TorrentItem(title: "A", seeders: 9000, leechers: 0, sizeBytes: 100,
            magnetLink: "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40))
        let second = TorrentItem(title: "B", seeders: 17, leechers: 0, sizeBytes: 100,
            magnetLink: "magnet:?xt=urn:btih:" + String(repeating: "b", count: 40))
        let larger = TorrentItem(title: "C", seeders: 1, leechers: 0, sizeBytes: 200, magnetLink: "")
        let unknown = TorrentItem(title: "D", seeders: 10000, leechers: 0, sizeBytes: 0, magnetLink: "")
        let state = SearchPeerCountState(estimate: TrackerPeerEstimate(seeders: 0, leechers: 0,
            checkedAt: Date(), tracker: URL(string: "udp://tracker.example:80/announce")!))
        let secondState = SearchPeerCountState(estimate: TrackerPeerEstimate(seeders: 17, leechers: 0,
            checkedAt: Date(), tracker: URL(string: "udp://tracker.example:80/announce")!))
        let states = [String(repeating: "a", count: 40): state, String(repeating: "b", count: 40): secondState]
        let items = [first, unknown, second, larger]
        #expect(SearchResultsSortOrder.sizeDescending.sorted(items, peerStates: states).map(\.id)
            == [larger, second, first, unknown].map(\.id))
        #expect(SearchResultsSortOrder.sizeAscending.sorted(items, peerStates: states).map(\.id)
            == [second, first, larger, unknown].map(\.id))
    }

    @Test func trackerEstimatesReplaceIndexedCountsIncludingZero() {
        let item = TorrentItem(title: "Ubuntu", seeders: 9000, leechers: 4000, sizeBytes: 1, magnetLink: "")
        let pending = SearchPeerCountState(isChecking: true)
        #expect(pending.seedersLabel(for: item) == "Unknown tracker seeders")
        let unknown = SearchPeerCountState(checkedAt: Date())
        #expect(unknown.seedersLabel(for: item) == "Unknown tracker seeders")
        #expect(unknown.leechersLabel(for: item) == "Unknown tracker leechers")
        #expect(unknown.detail == "Tracker estimate unknown")
        let checked = SearchPeerCountState(estimate: TrackerPeerEstimate(seeders: 0, leechers: 2,
            checkedAt: Date(), tracker: URL(string: "udp://tracker.example:80/announce")!))
        #expect(checked.seedersLabel(for: item) == "0 tracker seeders")
        #expect(checked.leechersLabel(for: item) == "2 tracker leechers")
        #expect(checked.detail?.contains("checked") == true)

    }

    @Test func downloadsShowObservedConnectionsInsteadOfSwarmEstimates() {
        let item = TorrentItem(title: "Actual connections", seeders: 4234, leechers: 552,
            sizeBytes: 1, magnetLink: "")
        var download = DownloadsViewModel.Download(torrent: item, status: .downloading,
            numPeers: 4, connectedSeeders: 1, connectedLeechers: 3,
            knownSeeders: 100, knownLeechers: 200, swarmSeeders: 300, swarmLeechers: 9,
            engineSwarmSeeders: 4234, engineSwarmLeechers: 552)
        #expect(download.displayedSeeders == 1)
        #expect(download.displayedLeechers == 3)
        #expect(download.compactSeederDescription == "1 connected seeder")
        #expect(download.compactLeecherDescription == "3 connected leechers")
        #expect(download.seederCountLabel == "connected seeders")
        #expect(download.seederCountHelp.contains("currently connected"))
        #expect(download.peerCountDetails[0].value == "4 peers · 1 seeder · 3 leechers")
        #expect(download.peerCountDetails[1].value == "300 peers")

        // Seeder and leecher connections update independently of estimates.
        download.numPeers = 5
        download.connectedSeeders = 4
        download.connectedLeechers = 1
        #expect(download.displayedSeeders == 4)
        #expect(download.displayedLeechers == 1)
        download.numPeers = 0
        #expect(download.displayedSeeders == 0)
        #expect(download.displayedLeechers == 0)

        download.status = .completed
        download.numPeers = 5
        download.isSeeding = true
        #expect(download.displayedSeeders == 4)
        #expect(download.displayedLeechers == 1)
        download.isSeeding = false
        #expect(download.displayedSeeders == 0)
        #expect(download.displayedLeechers == 0)
    }

    @Test func stoppedDownloadsNeverDisplayOldConnectionsOrEstimates() {
        let item = TorrentItem(title: "Stopped torrent", seeders: 4234, leechers: 552,
            sizeBytes: 1, magnetLink: "")
        for status in [DownloadsViewModel.Download.Status.paused, .completed, .failed] {
            var download = DownloadsViewModel.Download(torrent: item, status: status,
                numPeers: 4, connectedSeeders: 1, connectedLeechers: 3,
                swarmSeeders: 300, swarmLeechers: 9,
                engineSwarmSeeders: 4234, engineSwarmLeechers: 552)
            #expect(download.compactSeederDescription == "0 connected seeders")
            #expect(download.compactLeecherDescription == "0 connected leechers")
            #expect(download.peerCountDetails[0].value == "0 peers · 0 seeders · 0 leechers")
            download.clearConnectedPeers()
            #expect(download.numPeers == 0)
            #expect(download.connectedSeeders == 0)
            #expect(download.connectedLeechers == 0)
        }
        let fresh = DownloadsViewModel.Download(torrent: item)
        #expect(fresh.displayedSeeders == 0)
        #expect(fresh.displayedLeechers == 0)
    }

    @Test func localPeerEstimateRemainsAvailableWithoutTrackerScrape() {
        let torrent = TorrentItem(
            title: "Estimated",
            seeders: 0,
            leechers: 0,
            sizeBytes: 1_000,
            magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        )
        let download = DownloadsViewModel.Download(
            torrent: torrent,
            numPeers: 1,
            connectablePeers: 3,
            knownSeeders: 2,
            knownLeechers: 4
        )

        #expect(download.swarmPeerEstimate == nil)
        #expect(download.localPeerEstimate == 6)
        #expect(download.displayedPeerEstimate == 6)
        #expect(!download.hasTrackerSwarmEstimate)
    }

    @Test func engineSwarmEstimateIsNotHiddenBySmallerScrape() {
        let torrent = TorrentItem(
            title: "Engine estimate",
            seeders: 0,
            leechers: 0,
            sizeBytes: 1_000,
            magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        )
        let download = DownloadsViewModel.Download(
            torrent: torrent,
            swarmSeeders: 1,
            swarmLeechers: 1,
            engineSwarmSeeders: 10,
            engineSwarmLeechers: 12
        )

        #expect(download.trackerScrapePeerEstimate == 2)
        #expect(download.swarmPeerEstimate == 22)
        #expect(download.peerEstimateSource == "engine")
        #expect(download.peerCountDescription == "0 connected · 22 peers")
    }
}
