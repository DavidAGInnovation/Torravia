@testable import TorraviaSearchCore
import Foundation
import Network
import Testing
@testable import Torravia

@MainActor
struct SeedingLimitsTests {
    @Test func liveAPIUpdatesLimitsPreservesOmittedFieldsAndRejectsInvalidMinutes() async throws {
        let suite = "TorraviaTests.seedingLimits.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let preferences = SeedingPreferencesStore(userDefaults: defaults)
        preferences.remoteControlPort = Int.random(in: 20_000...60_000)
        let model = DownloadsViewModel(session: WebTorrentSession(), preferences: preferences,
            downloadLocation: DownloadLocationStore(userDefaults: defaults),
            automation: DownloadAutomationStore(userDefaults: defaults),
            persistenceURL: directory.appendingPathComponent("downloads.json"), startServices: false)
        let torrent = TorrentItem(title: "Policy fixture", seeders: 0, leechers: 0, sizeBytes: 100,
            magnetLink: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        var download = DownloadsViewModel.Download(torrent: torrent, progress: 1, status: .completed)
        download.downloadedBytes = 100
        download.seedingTimeSeconds = 20
        download.inactiveSeedingTimeSeconds = 10
        model.restoreDownloads([download])
        model.startRemoteControl()
        defer { model.remoteListener?.cancel(); model.remoteConnections.values.forEach { $0.cancel() } }
        for _ in 0..<100 {
            if model.remoteControlURL != nil || model.remoteControlError != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let root = try #require(model.remoteControlURL)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func request(_ values: [String: Any]?, authenticated: Bool = true) async throws -> (Data, Int) {
            var components = try #require(URLComponents(url: root.appendingPathComponent(
                values == nil ? "api/downloads/properties" : "api/downloads"), resolvingAgainstBaseURL: false))
            components.queryItems = [URLQueryItem(name: "id", value: download.id.uuidString)]
            var request = URLRequest(url: try #require(components.url))
            request.timeoutInterval = 5
            if authenticated { request.setValue("Bearer \(model.remoteControlToken)", forHTTPHeaderField: "Authorization") }
            if let values {
                request.httpMethod = "PUT"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: values)
            }
            let (data, response) = try await session.data(for: request)
            return (data, try #require(response as? HTTPURLResponse).statusCode)
        }
        #expect(try await request(["seedingTimeLimitMinutes": 60], authenticated: false).1 == 401)
        #expect(try await request(["seedingTimeLimitMinutes": 1440, "inactiveSeedingTimeLimitMinutes": 120,
                                  "shareRatioLimit": 2, "shareRatioAction": "pause"]).1 == 200)
        #expect(model.downloads.first?.seedingTimeLimitMinutes == 1440)
        #expect(model.downloads.first?.inactiveSeedingTimeLimitMinutes == 120)
        #expect(model.downloads.first?.shareRatioAction == .pause)
        #expect(try await request(["seedingTimeLimitMinutes": 60]).1 == 200)
        #expect(model.downloads.first?.inactiveSeedingTimeLimitMinutes == 120)
        for invalid in [-1, 1.5, "60", true, 5_256_001] as [Any] {
            #expect(try await request(["inactiveSeedingTimeLimitMinutes": invalid, "category": "invalid mutation"]).1 == 400)
            #expect(model.downloads.first?.inactiveSeedingTimeLimitMinutes == 120)
            #expect(model.downloads.first?.category == "")
        }
        let properties = try #require(JSONSerialization.jsonObject(with: try await request(nil).0) as? [String: Any])
        #expect(properties["seedingTimeSeconds"] as? Int == 20)
        #expect(properties["inactiveSeedingTimeSeconds"] as? Int == 10)
        #expect(try await request(["seedingTimeLimitMinutes": NSNull(), "inactiveSeedingTimeLimitMinutes": 0]).1 == 200)
        #expect(model.downloads.first?.seedingTimeLimitMinutes == nil)
        #expect(model.downloads.first?.inactiveSeedingTimeLimitMinutes == nil)
        model.persistDownloadsNow()
        await model.handle(sessionEvent: .seedingLimitReached(id: download.id.uuidString, action: "pause", reason: "inactivity"))
        #expect(model.downloads.first?.isSeedingDesired == false)
        #expect(model.downloads.first?.errorMessage == "Inactivity limit reached. Seeding paused.")
        let progress = WebTorrentSession.Event.Progress(id: download.id.uuidString, progress: 1,
            downloadSpeed: 0, uploadSpeed: 0, downloaded: 100, uploaded: 0, isQueued: false,
            numPeers: 0, connectablePeers: 0, connectedSeeders: 0, connectedLeechers: 0,
            knownPeers: 0, knownSeeders: 0, knownLeechers: 0, diskBacklogBytes: 0,
            diskQueueLimitBytes: 0, diskQueueWarnings: 0, schedulerRank: -1,
            swarmSeeders: nil, swarmLeechers: nil, timeRemaining: nil, path: directory,
            isProgressReady: true, isFinished: true, seedingTimeSeconds: 20, inactiveSeedingTimeSeconds: 10)
        await model.handle(sessionEvent: .progress(progress))
        model.flushPendingProgressEvents()
        #expect(model.downloads.first?.errorMessage == "Inactivity limit reached. Seeding paused.")
        await model.shutdownServices()
    }
}
