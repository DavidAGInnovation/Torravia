import TorraviaSearchCore
import Foundation

/// Reads creation settings while retaining metadata the creator does not expose.
@MainActor
enum TorrentMetadataEditor {
    struct Details {
        let result: CreatedTorrent
        let options: TorrentCreationOptions
    }

    static func read(data: Data) throws -> Details {
        guard data.count <= 64 * 1024 * 1024,
              case .dictionary(let root) = try Bencode.decode(data: data),
              Bencode.dictionary(root).encode() == data,
              case .dictionary(let info) = root["info"],
              case .integer(let pieceLength) = info["piece length"],
              TorrentCreationPreferences.pieceLengths.contains(pieceLength), pieceLength != 0,
              let summary = try DownloadsViewModel.parseTorrentFile(data: data),
              let hash = summary.infoHash ?? summary.v2InfoHash else {
            throw TorrentCreationError.invalidTorrentMetadata
        }
        let layout = try DownloadsViewModel.originalTorrentLayout(info: info)
        guard !layout.files.isEmpty, let size = summary.totalSize, size > 0,
              let count = summary.fileCount, count > 0 else {
            throw TorrentCreationError.invalidTorrentMetadata
        }
        let format: TorrentFormat = summary.v2InfoHash == nil ? .v1
            : summary.infoHash == nil ? .v2 : .hybrid
        let comment: String
        if case .string(let bytes) = root["comment.utf-8"] ?? root["comment"] {
            comment = String(decoding: bytes, as: UTF8.self)
        } else { comment = "" }
        let options = TorrentCreationOptions(format: format, trackers: summary.trackerURLs,
            comment: comment, isPrivate: info["private"] == .integer(1), pieceLength: pieceLength)
        let result = CreatedTorrent(data: data, name: summary.name, infoHash: hash,
            v1InfoHash: summary.infoHash, v2InfoHash: summary.v2InfoHash,
            totalBytes: Int(size), fileCount: count, pieceLength: pieceLength)
        return Details(result: result, options: options)
    }

    /// Sharing settings can be edited without rehashing or changing other metadata.
    static func update(data: Data, options: TorrentCreationOptions) throws -> CreatedTorrent {
        let previous = try read(data: data)
        guard options.format == previous.options.format,
              options.pieceLength == previous.options.pieceLength else {
            throw TorrentCreationError.originalsRequired
        }
        let trackers = try TorrentCreator.validatedTrackers(options)
        guard case .dictionary(var root) = try Bencode.decode(data: data),
              case .dictionary(var info) = root["info"] else {
            throw TorrentCreationError.invalidTorrentMetadata
        }
        if trackers != previous.options.trackers {
            root["announce"] = trackers.first.map { .string(Data($0.utf8)) }
            root["announce-list"] = trackers.isEmpty ? nil
                : .list(trackers.map { .list([.string(Data($0.utf8))]) })
        }
        if options.comment != previous.options.comment {
            root["comment.utf-8"] = nil
            root["comment"] = options.comment.isEmpty ? nil : .string(Data(options.comment.utf8))
        }
        if options.isPrivate != previous.options.isPrivate {
            info["private"] = options.isPrivate ? .integer(1) : nil
            root["info"] = .dictionary(info)
        }
        return try read(data: Bencode.dictionary(root).encode()).result
    }
}

nonisolated enum TorrentCreationPreferences {
    static let formatKey = "torrentCreator.format"
    static let pieceLengthKey = "torrentCreator.pieceLength"
    static let pieceLengths = [0, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384]
        .map { $0 * 1024 }

    static func format(in defaults: UserDefaults) -> TorrentFormat {
        defaults.string(forKey: formatKey).flatMap(TorrentFormat.init(rawValue:)) ?? .hybrid
    }

    static func pieceLength(in defaults: UserDefaults) -> Int {
        let value = defaults.integer(forKey: pieceLengthKey)
        return pieceLengths.contains(value) ? value : 0
    }
}
