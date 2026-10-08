import Foundation

/// A trusted local frontend package. API routes are never served from disk.
final class RemoteWebUIAssets {
    struct Asset {
        let data: Data
        let contentType: String
    }
    let directory: URL
    private let scopedURL: URL?
    static let maximumAssetSize = 8 * 1024 * 1024

    init(directory: URL) throws {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.scopedURL = directory.startAccessingSecurityScopedResource() ? directory : nil
        guard try asset(path: "/") != nil else {
            throw NSError(domain: "Torravia.WebUI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Choose a readable folder containing index.html."])
        }
    }

    convenience init(bookmark: Data) throws {
        var stale = false
        let directory = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                relativeTo: nil, bookmarkDataIsStale: &stale)
        try self.init(directory: directory)
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    func asset(path: String) throws -> Asset? {
        guard path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0.hasPrefix(".") }), parts.first != "api" else { return nil }
        let relative = parts.isEmpty ? "index.html" : parts.joined(separator: "/")
        let file = directory.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(directory.path + "/"),
              let type = Self.contentTypes[file.pathExtension.lowercased()] else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size <= Self.maximumAssetSize else { return nil }
        let data = try Data(contentsOf: file)
        guard data.count <= Self.maximumAssetSize else { return nil }
        return Asset(data: data, contentType: type)
    }

    private static let contentTypes: [String: String] = [
        "html": "text/html; charset=utf-8", "css": "text/css; charset=utf-8",
        "js": "application/javascript; charset=utf-8", "mjs": "application/javascript; charset=utf-8",
        "json": "application/json", "map": "application/json", "svg": "image/svg+xml",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp",
        "gif": "image/gif", "ico": "image/x-icon", "woff": "font/woff", "woff2": "font/woff2",
        "ttf": "font/ttf", "txt": "text/plain; charset=utf-8", "webmanifest": "application/manifest+json"
    ]
}
