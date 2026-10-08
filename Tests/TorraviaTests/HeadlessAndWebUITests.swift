@testable import TorraviaSearchCore
import Foundation
import Network
import Testing
@testable import Torravia

@MainActor
struct HeadlessAndWebUITests {
    @Test func optionsValidateAndDoNotPersistOverrides() throws {
        let options = try HeadlessOptions.parse(["--headless", "--webui-port", "34567", "--allow-lan"])
        #expect(options.port == 34567)
        #expect(options.allowsLAN)
        for args in [["--headless", "--webui-port", "0"], ["--headless", "--webui-port"],
                     ["--headless", "--unknown"], ["--headless", "--webui-directory", "relative"]] {
            #expect(throws: NSError.self) { try HeadlessOptions.parse(args) }
        }
        let suite = "TorraviaTests.headless.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let preferences = SeedingPreferencesStore(userDefaults: defaults)
        preferences.remoteControlPort = 12345
        preferences.remoteControlAllowsLAN = true
        let model = DownloadsViewModel(session: WebTorrentSession(), preferences: preferences,
                                      downloadLocation: DownloadLocationStore(userDefaults: defaults),
                                      automation: DownloadAutomationStore(userDefaults: defaults),
                                      persistenceURL: directory.appendingPathComponent("downloads.json"),
                                      startServices: false, headlessOptions: try HeadlessOptions.parse(["--headless", "--webui-port", "34567"]))
        #expect(model.isHeadless)
        #expect(model.remoteEnabled)
        #expect(!model.remoteAllowsLAN)
        #expect(model.remotePort == 34567)
        #expect(preferences.remoteControlPort == 12345)
        #expect(preferences.remoteControlAllowsLAN)
        #expect(!preferences.isRemoteControlEnabled)
    }

    @Test func assetsBlockEscapesAndPreserveBinaryData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let site = root.appendingPathComponent("site")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("custom interface".utf8).write(to: site.appendingPathComponent("index.html"))
        let binary = Data([0, 255, 128, 65])
        try binary.write(to: site.appendingPathComponent("image.png"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("secret.json"))
        try FileManager.default.createSymbolicLink(at: site.appendingPathComponent("escape.json"), withDestinationURL: root.appendingPathComponent("secret.json"))
        let assets = try RemoteWebUIAssets(directory: site)
        #expect(try assets.asset(path: "/image.png")?.data == binary)
        for path in ["/../secret.json", "/.hidden", "/escape.json", "/api/preferences", "/foo\\bar"] {
            #expect(try assets.asset(path: path) == nil)
        }
        let large = site.appendingPathComponent("large.png")
        try Data(repeating: 1, count: RemoteWebUIAssets.maximumAssetSize + 1).write(to: large)
        #expect(try assets.asset(path: "/large.png") == nil)
    }

    @Test func lockAndTokenFileAreSafeToReuse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var lock: TorraviaProcessLock? = try TorraviaProcessLock(directory: directory)
        #expect(throws: NSError.self) { try TorraviaProcessLock(directory: directory) }
        withExtendedLifetime(lock) {}
        lock = nil
        let next = try TorraviaProcessLock(directory: directory)
        withExtendedLifetime(next) {}
        let token = directory.appendingPathComponent("token")
        try HeadlessRuntime.writePrivateToken("first", to: token)
        try HeadlessRuntime.writePrivateToken("second", to: token)
        #expect(try String(contentsOf: token, encoding: .utf8) == "second\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: token.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func customFrontendKeepsAPIAuthenticationAndCanRevert() async throws {
        let suite = "TorraviaTests.webUI.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try Data("custom frontend".utf8).write(to: directory.appendingPathComponent("index.html"))
        let binary = Data([0, 255, 128, 65])
        try binary.write(to: directory.appendingPathComponent("image.png"))
        let preferences = SeedingPreferencesStore(userDefaults: defaults)
        preferences.remoteControlPort = Int.random(in: 20_000...60_000)
        let model = DownloadsViewModel(session: WebTorrentSession(), preferences: preferences,
                                      downloadLocation: DownloadLocationStore(userDefaults: defaults),
                                      automation: DownloadAutomationStore(userDefaults: defaults),
                                      persistenceURL: directory.appendingPathComponent("downloads.json"), startServices: false)
        model.alternativeWebUI = try RemoteWebUIAssets(directory: directory)
        model.startRemoteControl()
        defer { model.remoteListener?.cancel(); model.remoteConnections.values.forEach { $0.cancel() } }
        for _ in 0..<100 {
            if model.remoteControlURL != nil || model.remoteControlError != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let root = try #require(model.remoteControlURL)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func request(_ path: String, token: Bool = false, origin: String? = nil) async throws -> (Data, Int) {
            var request = URLRequest(url: root.appendingPathComponent(path))
            request.timeoutInterval = 5
            if token { request.setValue("Bearer \(model.remoteControlToken)", forHTTPHeaderField: "Authorization") }
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            let (data, response) = try await session.data(for: request)
            return (data, try #require(response as? HTTPURLResponse).statusCode)
        }
        let landing = try await request("")
        #expect(landing.1 == 200)
        #expect(String(decoding: landing.0, as: UTF8.self) == "custom frontend")
        let image = try await request("image.png")
        #expect(image.1 == 200)
        #expect(image.0 == binary)
        #expect(try await request("web.js").1 == 404)
        #expect(try await request("api/app").1 == 401)
        #expect(try await request("api/app", token: true).1 == 200)
        #expect(try await request("api/app", token: true, origin: "https://evil.example").1 == 403)
        model.alternativeWebUI = nil
        let stock = try await request("")
        #expect(stock.1 == 200)
        #expect(String(decoding: stock.0, as: UTF8.self).contains("Connect to your Mac"))
    }
}
