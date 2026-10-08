import TorraviaSearchCore
//
//  DownloadsViewModel+TorrentParsing.swift
//  Torravia
//
//  Magnet identity and torrent metadata parsing helpers.
//

import Foundation
import CryptoKit

extension DownloadsViewModel {
    func parseDisplayTitle(from magnet: String) -> String? {
        guard let url = MagnetLink.components(magnet) else { return nil }
        // Try to parse 'dn' (display name) parameter from magnet link
        if let dn = url.queryItems?.first(where: { $0.name.lowercased() == "dn" })?.value {
            return dn
        }
        return nil
    }

    typealias TorrentFileSummary = TorrentMetadata.TorrentFileSummary
    nonisolated static func canonicalMagnetIdentity(_ link: String) -> String? { TorrentMetadata.canonicalMagnetIdentity(link) }
    nonisolated static func isValidMagnetLink(_ link: String) -> Bool { TorrentMetadata.isValidMagnetLink(link) }
    nonisolated static func parseTorrentFile(data: Data) throws -> TorrentFileSummary? { try TorrentMetadata.parseTorrentFile(data: data) }
    nonisolated static func parseTorrentFile(at url: URL) throws -> TorrentFileSummary { try TorrentMetadata.parseTorrentFile(at: url) }
}
