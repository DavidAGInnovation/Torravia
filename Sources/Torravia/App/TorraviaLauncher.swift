import Foundation
import SwiftUI
import Darwin

/// The desktop and background modes share a queue, so only one may own it.
final class TorraviaProcessLock {
    private let descriptor: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handle = open(directory.appendingPathComponent("instance.lock").path,
                          O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard handle >= 0 else { throw HeadlessOptions.failure("Cannot open the Torravia queue lock.") }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            close(handle)
            throw HeadlessOptions.failure("Torravia is already running. Stop the desktop or headless instance first.")
        }
        descriptor = handle
    }
    deinit { close(descriptor) }
}

@main
@MainActor
enum TorraviaLauncher {
    private static var processLock: TorraviaProcessLock?

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") { print(HeadlessOptions.help); return }
        do {
            let headless = arguments.contains("--headless") ? try HeadlessOptions.parse(arguments) : nil
            // XCTest launches multiple hosts; their models use isolated fixture paths.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                processLock = try TorraviaProcessLock(directory: DownloadsViewModel.makeDownloadsPersistenceURL().deletingLastPathComponent())
            }
            if let headless {
                HeadlessRuntime.start(options: headless)
                dispatchMain()
            } else {
                TorraviaApp.main()
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
