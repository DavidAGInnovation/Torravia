import Foundation
import Darwin

@MainActor
enum HeadlessRuntime {
    private static var model: DownloadsViewModel?
    private static var startupTask: Task<Void, Never>?
    private static var signals: [DispatchSourceSignal] = []
    private static var stopping = false
    private static var tokenURL: URL?

    static func start(options: HeadlessOptions) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Task { @MainActor in await stop(code: 0) } }
            source.resume()
            signals.append(source)
        }
        startupTask = Task {
            do {
                let downloads = DownloadsViewModel(preferences: .shared, downloadLocation: .shared,
                                                    headlessOptions: options)
                model = downloads
                if let error = downloads.alternativeWebUIError { throw HeadlessOptions.failure(error) }
                guard !downloads.persistenceLoadFailed else { throw HeadlessOptions.failure("The saved queue could not be loaded.") }
                try await downloads.session.ensureRunning()
                for _ in 0..<200 {
                    try Task.checkCancellation()
                    if downloads.remoteControlURL != nil || downloads.remoteControlError != nil { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard let url = downloads.remoteControlURL else {
                    throw HeadlessOptions.failure(downloads.remoteControlError ?? "Browser control timed out while starting.")
                }
                let file = options.tokenFileURL ?? downloads.downloadsPersistenceURL.deletingLastPathComponent().appendingPathComponent("headless-token")
                if let interface = downloads.alternativeWebUI {
                    let path = file.standardizedFileURL.resolvingSymlinksInPath().path
                    guard !path.hasPrefix(interface.directory.path + "/") else {
                        throw HeadlessOptions.failure("The private token file must be outside the browser interface folder.")
                    }
                }
                try writePrivateToken(downloads.remoteControlToken, to: file)
                tokenURL = file
                print("Torravia headless ready: \(url.absoluteString)")
                for address in downloads.remoteControlLANURLs { print("Network address: \(address.absoluteString)") }
                print("Access token file: \(file.path)")
                fflush(stdout)
            } catch is CancellationError {
                // The signal handler owns shutdown.
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                await stop(code: 1)
            }
        }
    }

    static func writePrivateToken(_ token: String, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".token-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data((token + "\n").utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw HeadlessOptions.failure("Cannot write the private access token file.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, url.path) == 0 else { throw HeadlessOptions.failure("Cannot replace the access token file.") }
    }

    private static func stop(code: Int32) async {
        guard !stopping else { return }
        stopping = true
        startupTask?.cancel()
        await model?.shutdownServices()
        if let tokenURL { try? FileManager.default.removeItem(at: tokenURL) }
        exit(code)
    }
}
