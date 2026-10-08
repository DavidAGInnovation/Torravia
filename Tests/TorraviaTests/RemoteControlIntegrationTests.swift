@testable import TorraviaSearchCore
import Foundation
import Network
import Testing
@testable import Torravia

@MainActor
struct RemoteControlIntegrationTests {
    @Test func liveHTTPRequiresAuthenticationAndSavesSchedule() async throws {
        let suite = "TorraviaTests.remote.\(UUID())"
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
        model.startRemoteControl()
        defer { model.remoteListener?.cancel(); model.remoteConnections.values.forEach { $0.cancel() } }
        for _ in 0..<100 {
            if model.remoteControlURL != nil || model.remoteControlError != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let root = try #require(model.remoteControlURL)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func request(_ path: String, authenticated: Bool = true, method: String = "GET",
                     body: [String: Any]? = nil, origin: String? = nil, host: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: path.isEmpty ? root : try #require(URL(string: path, relativeTo: root)))
            request.timeoutInterval = 5
            request.httpMethod = method
            if authenticated { request.setValue("Bearer \(model.remoteControlToken)", forHTTPHeaderField: "Authorization") }
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            if let host { request.setValue(host, forHTTPHeaderField: "Host") }
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            return (data, try #require(response as? HTTPURLResponse))
        }
        let (html, landing) = try await request("", authenticated: false)
        #expect(landing.statusCode == 200)
        #expect(String(decoding: html, as: UTF8.self).contains("Connect to your Mac"))
        #expect(landing.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("frame-ancestors 'none'") == true)
        let (_, script) = try await request("web.js", authenticated: false)
        #expect(script.statusCode == 200)
        let (icons, iconResponse) = try await request("web-icons.svg", authenticated: false)
        #expect(iconResponse.statusCode == 200)
        #expect(iconResponse.mimeType == "image/svg+xml")
        #expect(String(decoding: icons, as: UTF8.self).contains("<symbol id=\"downloads\""))
        let (_, denied) = try await request("api/preferences", authenticated: false)
        #expect(denied.statusCode == 401)
        let (_, badOrigin) = try await request("api/preferences", origin: "https://evil.example")
        #expect(badOrigin.statusCode == 403)
        let (_, badHost) = try await request("api/preferences", host: "evil.example:\(preferences.remoteControlPort)")
        #expect(badHost.statusCode == 403)
        let (_, saved) = try await request("api/preferences", method: "PUT", body: [
            "downloadLimitMBps": 9,
            "bandwidthSchedule": ["enabled": true, "weekdays": [2, 6], "startMinute": 1320,
                                  "endMinute": 480, "downloadLimitMBps": 2, "uploadLimitMBps": 1]
        ])
        #expect(saved.statusCode == 200)
        #expect(preferences.downloadLimitMBps == 9)
        #expect(preferences.bandwidthSchedule.enabled)
        #expect(preferences.bandwidthSchedule.weekdays == [2, 6])
        let (payload, read) = try await request("api/preferences")
        #expect(read.statusCode == 200)
        let json = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let schedule = try #require(json["bandwidthSchedule"] as? [String: Any])
        #expect(schedule["startMinute"] as? Int == 1320)
        #expect(schedule["downloadLimitMBps"] as? Int == 2)
        let (_, invalidRSS) = try await request("api/rss", method: "POST", body: ["feedURL": "file:///tmp/feed", "episodeFilter": "2x1-10;"])
        #expect(invalidRSS.statusCode == 400)
        let (_, createdRSS) = try await request("api/rss", method: "POST", body: [
            "name": "Harbor", "feedURLs": ["https://example.com/a", "https://example.com/b"],
            "include": "Harbor", "episodeFilter": "2x1-10;", "smartEpisodeFilter": true,
            "downloadRepacks": true, "ignoreDays": 1, "maxItemsPerPoll": 7])
        #expect(createdRSS.statusCode == 200)
        let rule = try #require(model.automation.rssRules.first)
        model.automation.recordRSSMatch(id: rule.id, title: "Harbor.S02E05")
        let (_, patchedRSS) = try await request("api/rss?id=\(rule.id)", method: "PATCH", body: ["name": "Harbor HD"])
        #expect(patchedRSS.statusCode == 200)
        #expect(model.automation.rssRules.first?.previouslyMatchedEpisodes == ["2x5"])
        let (_, invalidPatch) = try await request("api/rss?id=\(rule.id)", method: "PUT", body: ["episodeFilter": "bad", "name": "Do not save"])
        #expect(invalidPatch.statusCode == 400)
        #expect(model.automation.rssRules.first?.name == "Harbor HD")
        let (preview, previewResponse) = try await request("api/rss/preview", method: "POST", body: ["id": rule.id.uuidString, "title": "Harbor.S02E06"])
        #expect(previewResponse.statusCode == 200)
        let previewJSON = try #require(JSONSerialization.jsonObject(with: preview) as? [String: Any])
        #expect(previewJSON["matches"] as? Bool == false) // Cooldown is included in previews.
        #expect(previewJSON["episodes"] as? [String] == ["2x6"])
        #expect(model.automation.rssRules.first?.previouslyMatchedEpisodes == ["2x5"])
        let (_, resetRSS) = try await request("api/rss?id=\(rule.id)", method: "POST", body: ["action": "reset-history"])
        #expect(resetRSS.statusCode == 200)
        #expect(model.automation.rssRules.first?.previouslyMatchedEpisodes.isEmpty == true)
        #expect(model.automation.rssRules.first?.lastMatch == nil)
        let (_, secondRSS) = try await request("api/rss", method: "POST", body: ["feedURL": "https://example.com/a", "name": "Other"])
        #expect(secondRSS.statusCode == 200)
        #expect(model.automation.rssRules.count == 2)
        let secondRule = try #require(model.automation.rssRules.last)
        let (_, movedRSS) = try await request("api/rss?id=\(secondRule.id)", method: "POST", body: ["action": "move-up"])
        #expect(movedRSS.statusCode == 200)
        #expect(model.automation.rssRules.first?.id == secondRule.id)
        let (_, deletedRSS) = try await request("api/rss?id=\(secondRule.id)", method: "DELETE")
        #expect(deletedRSS.statusCode == 200)
        #expect(model.automation.rssRules.count == 1)
        #expect(model.automation.rssFeedURLs.count == 2)
        let (_, invalidUpload) = try await request("api/torrent-file", method: "POST", body: ["data": "invalid base64"])
        #expect(invalidUpload.statusCode == 400)
    }
}
