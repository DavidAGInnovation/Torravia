import Foundation

public enum TorrentSearchError: LocalizedError {
    case invalidQuery
    case allProvidersFailed(query: String, reasons: [String])

    public var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "Please enter a valid search term."
        case let .allProvidersFailed(query, reasons):
            let details = reasons.joined(separator: "\n")
            return "All torrent search providers failed for \"\(query)\".\n\(details)"
        }
    }
}
