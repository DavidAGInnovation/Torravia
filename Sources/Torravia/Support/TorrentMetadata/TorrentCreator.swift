import TorraviaSearchCore
import Foundation

nonisolated enum TorrentFormat: String, CaseIterable, Sendable {
    case hybrid, v1, v2
    var title: String { self == .hybrid ? "Hybrid" : rawValue }
    var explanation: String {
        switch self {
        case .hybrid: return "Supports v1 and v2 clients with modern file verification."
        case .v1: return "Use for trackers that require the original v1 format."
        case .v2: return "Modern file verification. Requires v2-compatible clients and trackers."
        }
    }
}

nonisolated struct TorrentCreationOptions: Sendable, Equatable {
    var format: TorrentFormat = .hybrid
    var trackers: [String] = []
    var comment = ""
    var isPrivate = false
    /// Zero selects an automatic size. Explicit sizes are powers of two.
    var pieceLength = 0
}

nonisolated struct CreatedTorrent: Sendable {
    let data: Data
    let name: String
    let infoHash: String
    let v1InfoHash: String?
    let v2InfoHash: String?
    let totalBytes: Int
    let fileCount: Int
    let pieceLength: Int
}

nonisolated enum TorrentCreationError: LocalizedError {
    case invalidSource, torrentMetadataSource, invalidTorrentMetadata, originalsRequired, symbolicLink(String), changedFile(String), emptySource, invalidTracker(String), privateTrackerRequired, invalidPieceSize, tooLarge, engine(String)
    var errorDescription: String? {
        switch self {
        case .invalidSource: return "Choose a regular file or folder that Torravia can read."
        case .torrentMetadataSource: return "Choose the original file or folder to create a torrent. To share content from an existing .torrent file, use Add Torrent for Seeding."
        case .invalidTorrentMetadata: return "Choose a valid v1, v2, or hybrid .torrent file with a supported piece size."
        case .originalsRequired: return "Choose the original content before changing the torrent’s content, format, or piece size."
        case .symbolicLink(let path): return "Symbolic links are not included. Remove the link or choose its target: \(path)"
        case .changedFile(let path): return "The source changed while hashing. Try again when it is no longer being edited: \(path)"
        case .emptySource: return "The selected source contains no data."
        case .invalidTracker(let url): return "Invalid tracker address: \(url). Use an HTTP, HTTPS, or UDP URL."
        case .privateTrackerRequired: return "Private torrents require at least one tracker."
        case .invalidPieceSize: return "Choose a power-of-two piece size between 16 KiB and 16 MiB."
        case .engine(let message): return message
        case .tooLarge: return "This source would create too much torrent metadata. Choose a larger piece size or a smaller source."
        }
    }
}

nonisolated enum TorrentCreator {
    private struct SourceFile: Equatable {
        let url: URL
        let path: [String]
        let size: Int
        let modified: Date?
        let inode: UInt64
    }

    nonisolated private static func files(at source: URL) throws -> (Bool, [SourceFile]) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let values = try source.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { throw TorrentCreationError.symbolicLink(source.path) }
        let directory = values.isDirectory == true
        guard directory || values.isRegularFile == true else { throw TorrentCreationError.invalidSource }
        guard directory || source.pathExtension.lowercased() != "torrent" else {
            throw TorrentCreationError.torrentMetadataSource
        }
        var urls: [URL] = []
        if directory {
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw TorrentCreationError.invalidSource }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                let entry = try url.resourceValues(forKeys: keys)
                guard entry.isSymbolicLink != true else { throw TorrentCreationError.symbolicLink(url.path) }
                if entry.isRegularFile == true { urls.append(url) }
                else if entry.isDirectory != true { throw TorrentCreationError.invalidSource }
                if urls.count > 100_000 { throw TorrentCreationError.tooLarge }
            }
            if let enumerationError { throw enumerationError }
        } else { urls = [source] }
        let rootComponents = source.standardizedFileURL.pathComponents
        let entries = try urls.map { url -> SourceFile in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber else { throw TorrentCreationError.invalidSource }
            let path = directory ? Array(url.standardizedFileURL.pathComponents.dropFirst(rootComponents.count)) : [source.lastPathComponent]
            guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw TorrentCreationError.invalidSource }
            return SourceFile(url: url, path: path, size: size.intValue,
                              modified: attributes[.modificationDate] as? Date,
                              inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        }.sorted { $0.path.joined(separator: "/").utf8.lexicographicallyPrecedes($1.path.joined(separator: "/").utf8) }
        return (directory, entries)
    }

    nonisolated static func validatedTrackers(_ options: TorrentCreationOptions) throws -> [String] {
        let trackers = Array(NSOrderedSet(array: options.trackers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })) as? [String] ?? []
        for tracker in trackers {
            guard let url = URL(string: tracker), ["http", "https", "udp"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw TorrentCreationError.invalidTracker(tracker)
            }
        }
        if options.isPrivate && trackers.isEmpty { throw TorrentCreationError.privateTrackerRequired }
        return trackers
    }

    nonisolated static func create(source: URL, options: TorrentCreationOptions,
                                   progress: @Sendable (Double) -> Void = { _ in }) throws -> CreatedTorrent {
        try Task.checkCancellation()
        let trackers = try validatedTrackers(options)
        let (directory, entries) = try files(at: source)
        var total = 0
        for file in entries {
            let (sum, overflow) = total.addingReportingOverflow(file.size)
            guard !overflow, file.size >= 0 else { throw TorrentCreationError.tooLarge }
            total = sum
        }
        guard total > 0 else { throw TorrentCreationError.emptySource }
        var pieceLength = options.pieceLength
        if pieceLength == 0 {
            pieceLength = 256 * 1024
            while total / pieceLength > 2048 && pieceLength < 16 * 1024 * 1024 { pieceLength *= 2 }
        }
        guard pieceLength >= 16 * 1024, pieceLength <= 16 * 1024 * 1024,
              pieceLength & (pieceLength - 1) == 0 else { throw TorrentCreationError.invalidPieceSize }
        guard total / pieceLength < 1_000_000 else { throw TorrentCreationError.tooLarge }
        guard let helper = WebTorrentSession.bundledHelperExecutableURL() else {
            throw TorrentCreationError.engine("The bundled torrent engine is unavailable.")
        }
        let request: [String: Any] = [
            "format": options.format.rawValue, "pieceLength": pieceLength,
            "root": source.deletingLastPathComponent().path,
            "files": entries.map { ["path": (directory ? [source.lastPathComponent] + $0.path : $0.path).joined(separator: "/"), "size": $0.size] as [String: Any] },
            "trackers": trackers, "comment": options.comment, "private": options.isPrivate
        ]
        let data = try runEngine(helper: helper, request: request, progress: progress)
        let (_, finalEntries) = try files(at: source)
        guard entries == finalEntries else { throw TorrentCreationError.changedFile(source.path) }
        guard let summary = try DownloadsViewModel.parseTorrentFile(data: data),
              let hash = summary.infoHash ?? summary.v2InfoHash else {
            throw TorrentCreationError.engine("The engine returned invalid torrent metadata.")
        }
        progress(1)
        return CreatedTorrent(data: data, name: source.lastPathComponent,
                              infoHash: hash, v1InfoHash: summary.infoHash, v2InfoHash: summary.v2InfoHash,
                              totalBytes: total, fileCount: entries.count, pieceLength: pieceLength)
    }

    private static func runEngine(helper: URL, request: [String: Any],
                                  progress: @Sendable (Double) -> Void) throws -> Data {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = helper
        process.arguments = ["--create-torrent"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        var json = try JSONSerialization.data(withJSONObject: request)
        json.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: json)
        try input.fileHandleForWriting.close()
        var buffer = Data()
        var result: Data?
        while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            guard buffer.count <= 96 * 1024 * 1024 else { throw TorrentCreationError.tooLarge }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let event = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw TorrentCreationError.engine("The torrent engine returned an invalid response.")
                }
                if let message = event["error"] as? String { throw TorrentCreationError.engine(message) }
                if let value = event["progress"] as? Double { progress(value) }
                if let base64 = event["data"] as? String { result = Data(base64Encoded: base64) }
            }
        }
        try Task.checkCancellation()
        process.waitUntilExit()
        guard process.terminationStatus == 0, buffer.isEmpty, let result else {
            throw TorrentCreationError.engine("The torrent engine could not finish creating the torrent.")
        }
        return result
    }
}
