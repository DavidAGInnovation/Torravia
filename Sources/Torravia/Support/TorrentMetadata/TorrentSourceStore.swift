import TorraviaSearchCore
import Foundation

/// Local content locations are kept outside the shareable torrent metadata.
@MainActor
struct TorrentSourceStore {
    let url: URL

    func remember(data: Data, source: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let download = try DownloadsViewModel.originalSeedDownload(data: data,
            fileName: "", source: source, bookmark: nil)
        guard let hash = download.infoHash else { throw OriginalSeedingError.invalidTorrent }
        let bookmark = try source.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        var bookmarks = try load()
        bookmarks[hash] = bookmark
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(bookmarks).write(to: url, options: .atomic)
    }

    func source(for data: Data) throws -> URL? {
        guard let summary = try DownloadsViewModel.parseTorrentFile(data: data),
              let hash = summary.infoHash ?? summary.v2InfoHash else {
            throw OriginalSeedingError.invalidTorrent
        }
        guard let bookmark = try load()[hash] else { return nil }
        var stale = false
        let source = try URL(resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI], relativeTo: nil,
            bookmarkDataIsStale: &stale)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        // Recheck availability and layout. Piece hashes are still verified by the
        // engine when the user starts seeding, even for remembered locations.
        _ = try DownloadsViewModel.originalSeedDownload(data: data,
            fileName: "", source: source, bookmark: bookmark)
        if stale { try remember(data: data, source: source) }
        return source
    }

    private func load() throws -> [String: Data] {
        do { return try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
    }
}
