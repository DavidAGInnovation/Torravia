import Foundation
import CryptoKit

nonisolated public enum TorrentMetadata {
    nonisolated public static func canonicalMagnetIdentity(_ link: String) -> String? {
        let trimmedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = MagnetLink.components(trimmedLink),
              components.scheme?.lowercased() == "magnet",
              let queryItems = components.queryItems else {
            return nil
        }

        for item in queryItems where item.name.lowercased() == "xt" {
            guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            let lowercased = value.lowercased()
            if lowercased.hasPrefix("urn:btih:") {
                let hash = String(lowercased.dropFirst("urn:btih:".count))
                if let canonical = canonicalBTIHHash(hash) {
                    return "btih:\(canonical)"
                }
            } else if lowercased.hasPrefix("urn:btmh:") {
                let multihash = String(lowercased.dropFirst("urn:btmh:".count))
                if isValidBTMH(multihash) {
                    return "btmh:\(multihash)"
                }
            }
        }
        return nil
    }

    nonisolated public static func isValidMagnetLink(_ link: String) -> Bool {
        canonicalMagnetIdentity(link) != nil
    }

    nonisolated private static func canonicalBTIHHash(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidInfoHash(trimmed) else { return nil }
        let uppercased = trimmed.uppercased()
        let hexSet = CharacterSet(charactersIn: "0123456789ABCDEF")
        if uppercased.count == 40 && uppercased.unicodeScalars.allSatisfy(hexSet.contains) {
            return uppercased.lowercased()
        }
        guard let decoded = decodeBase32InfoHash(uppercased) else { return nil }
        return decoded.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func decodeBase32InfoHash(_ value: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt64 = 0
        var bitCount = 0
        var output = Data()
        for scalar in value.unicodeScalars {
            guard let index = alphabet.firstIndex(where: { $0 == Character(scalar) }) else { return nil }
            buffer = ((buffer << 5) | UInt64(index)) & 0xffff_ffff
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                output.append(UInt8((buffer >> UInt64(bitCount)) & 0xff))
            }
        }
        return output.count == 20 ? output : nil
    }

    nonisolated private static func isValidBTMH(_ raw: String) -> Bool {
        guard raw.count == 68, raw.hasPrefix("1220") else { return false }
        let hexSet = CharacterSet(charactersIn: "0123456789abcdef")
        return raw.dropFirst(4).unicodeScalars.allSatisfy(hexSet.contains)
    }

    nonisolated private static func isValidInfoHash(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let uppercased = trimmed.uppercased()
        let hexSet = CharacterSet(charactersIn: "0123456789ABCDEF")
        let base32Set = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        if uppercased.count == 40 && uppercased.unicodeScalars.allSatisfy(hexSet.contains) {
            return true
        }
        if uppercased.count == 32 && uppercased.unicodeScalars.allSatisfy(base32Set.contains) {
            return true
        }
        return false
    }

    nonisolated private static func extractInfoHash(from data: Data) throws -> String? {
        guard let infoDict = try Self.infoDictionary(from: data) else { return nil }
        let bencodedInfo = Self.encodeDictionary(infoDict)
        guard !bencodedInfo.isEmpty else { return nil }
        let sha1 = SHA1.hash(data: bencodedInfo)
        return sha1.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated public struct TorrentFileSummary {
        public let name: String
        public let totalSize: Int64?
        public let fileCount: Int?
        public let infoHash: String?
        public let rawSize: Int
        public let v2InfoHash: String?
        public let trackerURLs: [String]

        public var magnetLink: String? {
            var queryItems: [URLQueryItem] = []
            if let infoHash {
                queryItems.append(URLQueryItem(name: "xt", value: "urn:btih:\(infoHash)"))
            }
            if let v2InfoHash {
                queryItems.append(URLQueryItem(name: "xt", value: "urn:btmh:1220\(v2InfoHash)"))
            }
            guard !queryItems.isEmpty else { return nil }
            if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                queryItems.append(URLQueryItem(name: "dn", value: name))
            }
            queryItems.append(contentsOf: trackerURLs.map { URLQueryItem(name: "tr", value: $0) })
            var components = URLComponents()
            components.scheme = "magnet"
            components.queryItems = queryItems
            return components.string
        }
    }

    nonisolated public static func parseTorrentFile(at url: URL) throws -> TorrentFileSummary {
        let data = try Data(contentsOf: url)
        if let summary = try Self.parseTorrentFile(data: data) {
            return summary
        }
        return TorrentFileSummary(name: url.deletingPathExtension().lastPathComponent,
                                  totalSize: nil,
                                  fileCount: nil,
                                  infoHash: nil,
                                  rawSize: data.count,
                                  v2InfoHash: nil,
                                  trackerURLs: [])
    }

    nonisolated public static func parseTorrentFile(data: Data) throws -> TorrentFileSummary? {
        guard let root = try Self.rootDictionary(from: data),
              let infoValue = root["info"],
              case let .dictionary(infoDict) = infoValue else { return nil }

        let name: String
        if let nameValue = infoDict["name.utf-8"] ?? infoDict["name"],
           case let .string(nameData) = nameValue,
           let decodedName = String(data: nameData, encoding: .utf8) {
            name = decodedName
        } else {
            name = "Torrent"
        }

        var totalSize: Int64? = nil
        var fileCount: Int? = nil

        if let lengthValue = infoDict["length"], case let .integer(length) = lengthValue {
            totalSize = Int64(length)
            fileCount = 1
        } else if let filesValue = infoDict["files"], case let .list(files) = filesValue {
            var total: Int64 = 0
            var count = 0
            for file in files {
                guard case let .dictionary(fileDict) = file,
                      let lengthValue = fileDict["length"],
                      case let .integer(length) = lengthValue
                else { continue }
                total += Int64(length)
                count += 1
            }
            totalSize = total
            fileCount = count
        }

        if let fileTree = infoDict["file tree"] {
            let stats = Self.v2FileStats(fileTree)
            if stats.count > 0 {
                totalSize = stats.total
                fileCount = stats.count
            }
        }

        let hasV1Pieces = infoDict["pieces"] != nil || infoDict["length"] != nil || infoDict["files"] != nil
        let isV2: Bool = {
            guard let value = infoDict["meta version"],
                  case let .integer(version) = value else { return false }
            return version == 2
        }()
        let infoHash = hasV1Pieces ? Self.sha1Hash(of: infoDict) : nil
        let v2InfoHash = isV2 ? Self.sha256Hash(of: infoDict) : nil
        return TorrentFileSummary(name: name,
                                  totalSize: totalSize,
                                  fileCount: fileCount,
                                  infoHash: infoHash,
                                  rawSize: data.count,
                                  v2InfoHash: v2InfoHash,
                                  trackerURLs: Self.trackerURLs(from: root))
    }

    nonisolated private static func rootDictionary(from data: Data) throws -> [String: Bencode]? {
        guard let decoded = try? Bencode.decode(data: data),
              case let .dictionary(root) = decoded else { return nil }
        return root
    }

    nonisolated private static func infoDictionary(from data: Data) throws -> [String: Bencode]? {
        guard let root = try Self.rootDictionary(from: data),
              let infoValue = root["info"],
              case let .dictionary(infoDict) = infoValue
        else { return nil }
        return infoDict
    }

    nonisolated private static func trackerURLs(from root: [String: Bencode]) -> [String] {
        var result: [String] = []

        func append(_ value: Bencode) {
            switch value {
            case let .string(data):
                let url = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty,
                      !result.contains(where: { $0.caseInsensitiveCompare(url) == .orderedSame }) else { return }
                result.append(url)
            case let .list(values):
                values.forEach(append)
            case .integer, .dictionary, .binaryDictionary:
                break
            }
        }

        if let announce = root["announce"] {
            append(announce)
        }
        if let announceList = root["announce-list"] {
            append(announceList)
        }
        return result
    }

    nonisolated private static func encodeDictionary(_ dict: [String: Bencode]) -> Data {
        Bencode.dictionary(dict).encode()
    }

    nonisolated private static func sha1Hash(of dict: [String: Bencode]) -> String? {
        let bencodedInfo = encodeDictionary(dict)
        guard !bencodedInfo.isEmpty else { return nil }
        let sha1 = SHA1.hash(data: bencodedInfo)
        return sha1.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func sha256Hash(of dict: [String: Bencode]) -> String? {
        let bencodedInfo = encodeDictionary(dict)
        guard !bencodedInfo.isEmpty else { return nil }
        let digest = SHA256.hash(data: bencodedInfo)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func v2FileStats(_ value: Bencode) -> (total: Int64, count: Int) {
        switch value {
        case .dictionary(let dictionary):
            if let lengthValue = dictionary["length"],
               case let .integer(length) = lengthValue,
               length >= 0 {
                return (Int64(length), 1)
            }
            return dictionary.reduce(into: (total: Int64(0), count: 0)) { result, entry in
                let child = Self.v2FileStats(entry.value)
                if child.total > 0, result.total <= Int64.max - child.total {
                    result.total += child.total
                } else if child.total > 0 {
                    result.total = Int64.max
                }
                result.count += child.count
            }
        case .list(let values):
            return values.reduce(into: (total: Int64(0), count: 0)) { result, childValue in
                let child = Self.v2FileStats(childValue)
                if child.total > 0, result.total <= Int64.max - child.total {
                    result.total += child.total
                } else if child.total > 0 {
                    result.total = Int64.max
                }
                result.count += child.count
            }
        case .integer, .string, .binaryDictionary:
            return (0, 0)
        }
    }
}
