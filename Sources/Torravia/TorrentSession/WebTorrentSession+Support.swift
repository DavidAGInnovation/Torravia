import Foundation

extension WebTorrentSession {
    func send(command: [String: Any]) throws {
        guard let process, process.isRunning, let stdinPipe else {
            throw HelperError.processNotRunning
        }
        var json = try JSONSerialization.data(withJSONObject: command, options: [])
        json.append(0x0A)
        stdinPipe.fileHandleForWriting.write(json)
    }

    func sendNetworkConfiguration(_ configuration: NetworkConfiguration) throws {
        try send(command: [
            "type": "configure",
            "listenPort": configuration.listenPort,
            "globalConnectionLimit": configuration.globalConnectionLimit,
            "perTorrentConnectionLimit": configuration.perTorrentConnectionLimit,
            "downloadLimit": configuration.downloadLimitBytesPerSecond,
            "uploadLimit": configuration.uploadLimitBytesPerSecond,
            "globalUploadSlots": configuration.globalUploadSlots,
            "perTorrentUploadSlots": configuration.perTorrentUploadSlots,
            "queueingEnabled": configuration.queueingEnabled,
            "maximumActiveDownloads": configuration.maximumActiveDownloads,
            "maximumActiveSeeds": configuration.maximumActiveSeeds,
            "maximumActiveTorrents": configuration.maximumActiveTorrents,
            "ignoreSlowTorrents": configuration.ignoreSlowTorrents,
            "networkInterface": configuration.networkInterface,
            "transportMode": configuration.transportMode,
            "encryptionMode": configuration.encryptionMode,
            "diskIOBackend": configuration.diskIOBackend,
            "diskIOReadMode": configuration.diskIOReadMode,
            "diskIOWriteMode": configuration.diskIOWriteMode,
            "preallocateFiles": configuration.preallocateFiles,
            "outgoingPortStart": configuration.outgoingPortStart,
            "outgoingPortEnd": configuration.outgoingPortEnd,
            "additionalTrackerURLs": configuration.additionalTrackerURLs,
            "adaptiveTrackerURLs": configuration.adaptiveTrackerURLs,
            "dhtEnabled": configuration.dhtEnabled,
            "peerExchangeEnabled": configuration.peerExchangeEnabled,
            "localPeerDiscoveryEnabled": configuration.localPeerDiscoveryEnabled,
            "upnpEnabled": configuration.upnpEnabled,
            "natpmpEnabled": configuration.natpmpEnabled,
            "proxyType": configuration.proxyType,
            "proxyHost": configuration.proxyHost,
            "proxyPort": configuration.proxyPort,
            "proxyUsername": configuration.proxyUsername,
            "proxyPassword": configuration.proxyPassword,
            "proxyPeerConnections": configuration.proxyPeerConnections,
            "proxyHostnames": configuration.proxyHostnames,
            "proxyTrackerConnections": configuration.proxyTrackerConnections,
            "anonymousMode": configuration.anonymousMode,
            "ssrfMitigationEnabled": configuration.ssrfMitigationEnabled,
            "validateHTTPSTrackers": configuration.validateHTTPSTrackers,
            "blockPrivilegedPeerPorts": configuration.blockPrivilegedPeerPorts,
            "allowMultipleConnectionsPerIP": configuration.allowMultipleConnectionsPerIP,
            "i2pEnabled": configuration.i2pEnabled,
            "i2pHost": configuration.i2pHost,
            "i2pPort": configuration.i2pPort,
            "i2pMixedMode": configuration.i2pMixedMode,
            "blockedIPRanges": configuration.blockedIPRanges
        ])
    }

    func prepareHelperContext() throws -> HelperContext {
        if let existing = helperContext {
            return existing
        }

        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let helperDir = support.appendingPathComponent("\(TorrentSearchSite.stateDirectoryName)/native-helper", isDirectory: true)
        try fm.createDirectory(at: helperDir, withIntermediateDirectories: true)
        let context = HelperContext(directory: helperDir)
        helperContext = context
        return context
    }

    func appendLog(_ message: String) {
        guard let handle = logFileHandle else { return }
        let timestamp = Self.logDateFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    func closeLogFile() {
        try? logFileHandle?.close()
        logFileHandle = nil
        logFileURL = nil
    }

    static func makeLogFile(in directory: URL) throws -> (URL, FileHandle) {
        let fm = FileManager.default
        let logsDir = directory.appendingPathComponent("logs", isDirectory: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let filename = "native-helper-\(logDateFormatter.string(from: Date())).log"
        let logURL = logsDir.appendingPathComponent(filename)
        try "=== Native helper session started at \(Date()) ===\n".write(to: logURL, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        return (logURL, handle)
    }

    static func bundledHelperExecutableURL() -> URL? {
        let bundle = Bundle.main
        if let executable = bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("TorrentNativeHelper"),
           FileManager.default.isExecutableFile(atPath: executable.path) {
            return executable
        }

#if DEBUG
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent(".build/native-helper-test/Torravia.app/Contents/MacOS/TorrentNativeHelper"),
            cwd.appendingPathComponent(".build/DerivedData/Build/Products/Debug/Torravia.app/Contents/MacOS/TorrentNativeHelper")
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
#endif
        return nil
    }

    static let logDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func decodingErrorDescription(_ error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "missing key \(key.stringValue) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case let DecodingError.typeMismatch(type, context):
            return "expected \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case let DecodingError.valueNotFound(type, context):
            return "missing \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case let DecodingError.dataCorrupted(context):
            return "invalid data at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default:
            return error.localizedDescription
        }
    }

    struct HelperContext {
        let directory: URL
    }

    struct HelperMessage: Decodable {
        struct FileInfo: Decodable {
            let name: String
            let length: Int64?
            let isPadding: Bool?
        }

        struct PeerInfo: Decodable {
            let address: String
            let port: Int
            let client: String
            let transport: String
            let direction: String
            let sources: [String]
            let downloadSpeed: Double
            let uploadSpeed: Double
            let progress: Double
            let isSeed: Bool
        }

        struct TrackerInfo: Decodable {
            let url: String
            let tier: Int
            let state: String
            let source: Int
            let fails: Int
            let updating: Bool
            let message: String
            let scrapeComplete: Int?
            let scrapeIncomplete: Int?
        }

        struct InspectionFileInfo: Decodable {
            let index: Int
            let name: String
            let length: Int64?
            let progress: Double?
            let availability: Double?
            let priority: Int?
            let pieceStart: Int?
            let pieceEnd: Int?
        }

        struct InspectionPieceInfo: Decodable {
            let index: Int
            let have: Bool
            let availability: Int
            let priority: Int
            let hash: String
        }

        let type: String
        let id: String?
        let name: String?
        let infoHash: String?
        let path: String?
        let length: Int64?
        let files: [FileInfo]?
        let progress: Double?
        let downloadSpeed: Double?
        let uploadSpeed: Double?
        let downloaded: Double?
        let uploaded: Double?
        let seedingTimeSeconds: Int64?
        let inactiveSeedingTimeSeconds: Int64?
        let reason: String?
        let isQueued: Bool?
        let isProgressReady: Bool?
        let isFinished: Bool?
        let numPeers: Int?
        let connectablePeers: Int?
        let connectedSeeders: Int?
        let connectedLeechers: Int?
        let knownPeers: Int?
        let knownSeeders: Int?
        let knownLeechers: Int?
        let diskBacklogBytes: Int64?
        let diskQueueLimitBytes: Int64?
        let diskQueueWarnings: Int?
        let schedulerRank: Int?
        let swarmSeeders: Int?
        let swarmLeechers: Int?
        let metainfo: String?
        let timeRemaining: Double?
        let listenPort: Int?
        let isListening: Bool?
        let listenState: String?
        let connectionLimit: Int?
        let engineVersion: String?
        let upnpStatus: String?
        let natpmpStatus: String?
        let trackerStatus: String?
        let trackerAnnounces: Int?
        let trackerReplies: Int?
        let trackerErrors: Int?
        let alertsDropped: Int?
        let lastTrackerURL: String?
        let lastTrackerError: String?
        let dhtStatus: String?
        let dhtReplies: Int?
        let dhtNodes: Int?
        let availability: Double?
        let peers: [PeerInfo]?
        let trackers: [TrackerInfo]?
        let webSeeds: [String]?
        let trackerPeers: Int?
        let pieces: [Int]?
        let pieceLength: Int?
        let inspectionFiles: [InspectionFileInfo]?
        let inspectionPieces: [InspectionPieceInfo]?
        let action: String?
        let message: String?
        let announceType: String?
    }

    enum HelperError: LocalizedError {
        case processNotRunning
        case processTerminated
        case helperMissing
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .processNotRunning:
                return "Torrent helper is not running."
            case .processTerminated:
                return "Torrent helper terminated unexpectedly."
            case .helperMissing:
                return "Native torrent helper is missing from the app bundle."
            case .launchFailed(let message):
                return "Failed to launch native torrent helper: \(message)"
            }
        }
    }
}
