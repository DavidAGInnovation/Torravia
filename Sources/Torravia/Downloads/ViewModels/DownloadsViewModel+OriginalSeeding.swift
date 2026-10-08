import TorraviaSearchCore
import Foundation

enum OriginalSeedingError: LocalizedError {
    case invalidTorrent
    case invalidPath
    case wrongSourceType(isSingleFile: Bool)
    case missingFile(String)
    case incompleteFolder(firstUnavailableFile: String)
    case fileSizeMismatch(expectedFile: String, selectedFile: String, expectedBytes: Int64, actualBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidTorrent: return "Choose a valid v1, v2, or hybrid file or folder torrent."
        case .invalidPath: return "The torrent contains an unsafe or unsupported file path."
        case .wrongSourceType(let isSingleFile): return isSingleFile
            ? "Select the original file or the folder containing it."
            : "Select the original content folder for this torrent."
        case .missingFile(let path): return "The torrent requires ‘\(path)’, but it could not be found or read in the selected location. Select the original content for this torrent."
        case .incompleteFolder(let path):
            return "The selected folder does not match this torrent’s contents. The first missing or unreadable file is ‘\(path)’. Select the original folder containing all required files."
        case .fileSizeMismatch(let expectedFile, let selectedFile, let expectedBytes, let actualBytes):
            return "The selected file ‘\(selectedFile)’ has \(actualBytes.formatted()) bytes. This torrent expects ‘\(expectedFile)’ with \(expectedBytes.formatted()) bytes. Select the original content for this torrent."
        }
    }
}

@MainActor
extension DownloadsViewModel {
    var torrentSourceStore: TorrentSourceStore {
        TorrentSourceStore(url: downloadsPersistenceURL.deletingLastPathComponent()
            .appendingPathComponent("original-content.json"))
    }

    /// Validate the layout without changing the originals. The engine verifies piece hashes next.
    static func originalSeedDownload(data: Data, fileName: String, source: URL,
                                     bookmark: Data?) throws -> Download {
        guard case .dictionary(let root) = try Bencode.decode(data: data),
              case .dictionary(let info) = root["info"],
              let summary = try parseTorrentFile(data: data), let hash = summary.infoHash ?? summary.v2InfoHash,
              let magnet = summary.magnetLink else { throw OriginalSeedingError.invalidTorrent }
        func component(_ value: Bencode?) throws -> String {
            guard case .string(let bytes) = value, let text = String(data: bytes, encoding: .utf8),
                  !text.isEmpty, text != ".", text != "..",
                  !text.contains("/"), !text.contains("\\"), !text.contains("\0")
            else { throw OriginalSeedingError.invalidPath }
            return text
        }
        let name = try component(info["name.utf-8"] ?? info["name"])
        var source = source.standardizedFileURL
        let layout = try originalTorrentLayout(info: info)
        let isSingleFile = layout.isSingleFile
        var sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isSymbolicLink != true else { throw OriginalSeedingError.invalidPath }
        if isSingleFile && sourceValues.isDirectory == true {
            // Folder selection resolves only the exact metadata filename. Never
            // guess from similarly sized siblings or recurse into unrelated files.
            source = source.appendingPathComponent(name)
            guard let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
                throw OriginalSeedingError.missingFile(name)
            }
            sourceValues = values
            guard sourceValues.isSymbolicLink != true else { throw OriginalSeedingError.invalidPath }
        }
        let sourceName = try component(.string(Data(source.lastPathComponent.utf8)))
        guard isSingleFile ? sourceValues.isRegularFile == true : sourceValues.isDirectory == true else {
            throw OriginalSeedingError.wrongSourceType(isSingleFile: isSingleFile)
        }
        let entries = layout.files.map { file in
            Download.FileEntry(relativePath: ([sourceName] + (isSingleFile ? [] : file.path)).joined(separator: "/"), length: file.length)
        }
        guard !entries.isEmpty, Set(entries.map(\.relativePath)).count == entries.count else {
            throw OriginalSeedingError.invalidTorrent
        }
        let parent = source.deletingLastPathComponent()
        for entry in entries {
            let url = parent.appendingPathComponent(entry.relativePath)
            let expectedPath = isSingleFile ? name
                : name + String(entry.relativePath.dropFirst(sourceName.count))
            guard url.resolvingSymlinksInPath().path == parent.resolvingSymlinksInPath()
                .appendingPathComponent(entry.relativePath).path,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let fileSize = values.fileSize else {
                if isSingleFile { throw OriginalSeedingError.missingFile(expectedPath) }
                throw OriginalSeedingError.incompleteFolder(firstUnavailableFile: expectedPath)
            }
            guard Int64(fileSize) == entry.length else {
                throw OriginalSeedingError.fileSizeMismatch(expectedFile: expectedPath,
                    selectedFile: entry.relativePath, expectedBytes: entry.length, actualBytes: Int64(fileSize))
            }
        }
        var download = Download(torrent: .init(title: name, seeders: 0, leechers: 0,
            sizeBytes: summary.totalSize ?? 0, magnetLink: magnet),
            destinationURL: source, storageURL: parent,
            storageBookmark: bookmark, totalBytes: summary.totalSize,
            errorMessage: "Verifying original files…", infoHash: hash, files: entries,
            torrentData: data, torrentFileName: fileName, hasAnnouncedCompletion: true)
        download.contentRootURL = parent
        download.isSeedOnly = true
        download.isSeedingDesired = true
        return download
    }

    /// Physical files only: BEP 47 padding is virtual and must never be
    /// required on disk or mapped onto a user's original files.
    static func originalTorrentLayout(info: [String: Bencode]) throws -> (isSingleFile: Bool, files: [(path: [String], length: Int64)]) {
        func component(_ value: Bencode) throws -> String {
            guard case .string(let bytes) = value, let text = String(data: bytes, encoding: .utf8),
                  !text.isEmpty, text != ".", text != "..", !text.contains("/"),
                  !text.contains("\\"), !text.contains("\0") else { throw OriginalSeedingError.invalidPath }
            return text
        }
        if case .string = info["pieces"] {
            if case .integer(let length) = info["length"], length >= 0 {
                return (true, [([], Int64(length))])
            }
            guard case .list(let files) = info["files"] else { throw OriginalSeedingError.invalidTorrent }
            var entries: [(path: [String], length: Int64)] = []
            for file in files {
                guard case .dictionary(let attributes) = file,
                      case .integer(let length) = attributes["length"], length >= 0,
                      case .list(let path) = attributes["path.utf-8"] ?? attributes["path"], !path.isEmpty
                else { throw OriginalSeedingError.invalidTorrent }
                let components = try path.map(component)
                if case .string(let flags) = attributes["attr"], flags.contains(UInt8(ascii: "p")) { continue }
                entries.append((components, Int64(length)))
            }
            return (false, entries)
        }
        guard info["meta version"] == .integer(2), case .dictionary(let tree) = info["file tree"] else {
            throw OriginalSeedingError.invalidTorrent
        }
        var entries: [(path: [String], length: Int64)] = []
        func walk(_ tree: [String: Bencode], path: [String]) throws {
            for key in tree.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                guard case .dictionary(let child) = tree[key] else { throw OriginalSeedingError.invalidTorrent }
                if key.isEmpty {
                    guard tree.count == 1, !path.isEmpty,
                          case .integer(let length) = child["length"], length >= 0 else { throw OriginalSeedingError.invalidTorrent }
                    if length > 0 {
                        guard case .string(let hash) = child["pieces root"], hash.count == 32 else { throw OriginalSeedingError.invalidTorrent }
                    }
                    entries.append((path, Int64(length)))
                } else {
                    try walk(child, path: path + [try component(.string(Data(key.utf8)))])
                }
            }
        }
        try walk(tree, path: [])
        let name = try component(info["name.utf-8"] ?? info["name"] ?? .string(Data()))
        return (entries.count == 1 && entries[0].path == [name], entries)
    }

    func seedOriginalTorrent(data: Data, fileName: String, source: URL) throws -> UUID {
        let bookmark = try source.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        let download = try Self.originalSeedDownload(data: data, fileName: fileName,
                                                    source: source, bookmark: bookmark)
        guard !downloads.contains(where: { $0.infoHash == download.infoHash ||
            Self.canonicalMagnetIdentity($0.torrent.magnetLink) == Self.canonicalMagnetIdentity(download.torrent.magnetLink) }) else {
            throw NSError(domain: "Torravia", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "This torrent is already in Downloads. Use its seeding control, or remove it before selecting the originals."])
        }
        // Persist metadata before appending so restoring never depends on the .torrent file's location.
        _ = try persistTorrentDataIfNeeded(for: download)
        activateStoredSecurityScope(for: download)
        replaceDownloads(downloads + [download])
        restartOriginalSeed(download)
        return download.id
    }

    func restartOriginalSeed(_ download: Download) {
        guard download.isSeedOnly, let storage = download.storageURL else { return }
        activateStoredSecurityScope(for: download)
        update(downloadID: download.id) { d in
            d.status = .queued
            d.isSeeding = false
            d.isSeedingDesired = true
            d.progress = 0
            d.errorMessage = "Verifying original files…"
        }
        let match = ExistingDownloadMatch(destinationURL: download.destinationURL ?? storage,
            storageURL: storage, flattenedTargetURL: nil, totalBytes: download.totalBytes,
            fileEntries: download.files, infoHash: download.infoHash)
        Task { await startSeedingExistingDownload(download, match: match) }
    }
}
