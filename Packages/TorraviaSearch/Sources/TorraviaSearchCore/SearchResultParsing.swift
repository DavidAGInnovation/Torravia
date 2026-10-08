import Foundation

private let magnetQueryAllowedCharacters: CharacterSet = {
    // For magnet link parameters, we need to allow most URL characters
    // but avoid encoding common URL components like :, /, ?, etc.
    // We primarily need to escape: & (parameter separator), = (key-value separator)
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=\"\n\r")
    return allowed
}()

public struct HTTPStatusError: LocalizedError {
    public let url: URL
    public let statusCode: Int

    public init(url: URL, statusCode: Int) { self.url = url; self.statusCode = statusCode }

    public var errorDescription: String? {
        let host = url.host ?? url.absoluteString
        return "Request to \(host) failed with status code \(statusCode)."
    }
}



public func buildMagnetLink(infoHash: String, title: String, trackers: [String]) -> String? {
    guard let normalized = normalizeInfoHash(infoHash) else { return nil }
    var magnet = "magnet:?xt=urn:btih:\(normalized)"
    if let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: magnetQueryAllowedCharacters) {
        magnet.append("&dn=\(encodedTitle)")
    }
    for tracker in trackers {
        guard let encoded = tracker.addingPercentEncoding(withAllowedCharacters: magnetQueryAllowedCharacters) else { continue }
        magnet.append("&tr=\(encoded)")
    }
    return magnet
}

public func firstMatch(in string: String, pattern: String, options: NSRegularExpression.Options = []) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    let range = NSRange(string.startIndex..., in: string)
    guard let match = regex.firstMatch(in: string, range: range), match.numberOfRanges > 1,
          let capturedRange = Range(match.range(at: 1), in: string) else {
        return nil
    }
    return String(string[capturedRange])
}

public func matchGroups(in string: String, pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    let range = NSRange(string.startIndex..., in: string)
    guard let match = regex.firstMatch(in: string, range: range), match.numberOfRanges > 1 else { return nil }

    var groups: [String] = []
    for index in 1..<match.numberOfRanges {
        if let groupRange = Range(match.range(at: index), in: string) {
            groups.append(String(string[groupRange]))
        } else {
            groups.append("")
        }
    }
    return groups
}

public func decodeHTMLEntities(_ string: String) -> String {
    var result = string
    let replacements: [(String, String)] = [
        ("&amp;", "&"),
        ("&quot;", "\""),
        ("&#34;", "\""),
        ("&#39;", "'"),
        ("&#x27;", "'"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&#x2F;", "/"),
        ("&nbsp;", " "),
        ("&ndash;", "-"),
        ("&mdash;", "-")
    ]
    for (entity, replacement) in replacements {
        result = result.replacingOccurrences(of: entity, with: replacement)
    }

    if let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#, options: []) {
        let range = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, options: [], range: range)
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let valueRange = Range(match.range(at: 1), in: result) else { continue }
            let token = result[valueRange]
            let scalarValue: UInt32?
            if token.lowercased().hasPrefix("x") {
                let hexPart = token.dropFirst()
                scalarValue = UInt32(hexPart, radix: 16)
            } else {
                scalarValue = UInt32(token, radix: 10)
            }
            guard let scalarValue, let scalar = UnicodeScalar(scalarValue) else { continue }
            result.replaceSubrange(fullRange, with: String(scalar))
        }
    }

    return result
}

public func containsCloudflareBlock(in html: String) -> Bool {
    let lowercased = html.lowercased()
    return lowercased.contains("just a moment") && lowercased.contains("cloudflare")
        || lowercased.contains("__cf_chl")
        || lowercased.contains("cf-browser-verification")
}

public func buildProviderError(site: String, message: String) -> Error {
    NSError(domain: "TorrentSearch.\(site.replacingOccurrences(of: " ", with: ""))", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

extension Array {
    public subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

public func normalizeInfoHash(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let uppercased = trimmed.uppercased()

    let hexSet = CharacterSet(charactersIn: "0123456789ABCDEF")
    let base32Set = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    if uppercased.count == 40 && uppercased.unicodeScalars.allSatisfy(hexSet.contains) {
        return uppercased
    }
    if uppercased.count == 32 && uppercased.unicodeScalars.allSatisfy(base32Set.contains) {
        return uppercased
    }
    return nil
}

public func isValidMagnetLinkCandidate(_ magnet: String) -> Bool {
    TorrentMetadata.isValidMagnetLink(magnet)
}

public func parseByteCount(from value: String, preferBinary: Bool = false) -> Int64? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let separators = CharacterSet(charactersIn: " \u{00a0}")
    let normalizedValue = trimmed.replacingOccurrences(of: #"(?i)([0-9])[ ]*([A-Za-z])"#,
                                                       with: "$1 $2",
                                                       options: [.regularExpression])
    let components = normalizedValue.components(separatedBy: separators).filter { !$0.isEmpty }
    guard components.count >= 2 else { return nil }
    var numericPartRaw = components[0]
    let hasComma = numericPartRaw.contains(",")
    let hasDot = numericPartRaw.contains(".")
    if hasComma && !hasDot {
        numericPartRaw = numericPartRaw.replacingOccurrences(of: ",", with: ".")
    } else {
        numericPartRaw = numericPartRaw.replacingOccurrences(of: ",", with: "")
    }
    guard let magnitude = Double(numericPartRaw) else { return nil }
    let originalUnit = components[1].uppercased()
    let isBinary = originalUnit.contains("I")
    let normalizedUnit = originalUnit.replacingOccurrences(of: "I", with: "")

    let decimalMultipliers: [String: Double] = [
        "B": 1,
        "KB": 1_000,
        "MB": 1_000_000,
        "GB": 1_000_000_000,
        "TB": 1_000_000_000_000,
        "PB": 1_000_000_000_000_000
    ]

    let binaryMultipliers: [String: Double] = [
        "B": 1,
        "KB": 1024,
        "MB": 1_048_576,
        "GB": 1_073_741_824,
        "TB": 1_099_511_627_776,
        "PB": 1_125_899_906_842_624
    ]

    let lookup = (isBinary || preferBinary) ? binaryMultipliers : decimalMultipliers
    guard let factor = lookup[normalizedUnit] else { return nil }
    let bytes = magnitude * factor
    return Int64(bytes.rounded())
}

extension String {
    public var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
