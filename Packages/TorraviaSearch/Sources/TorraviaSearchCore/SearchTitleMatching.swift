import Foundation

/// Keeps provider noise from consuming the aggregate result cap.  A few
/// public indexes return a latest-items page when their search endpoint is
/// unavailable; those rows must not crowd out real matches from another
/// provider before `SearchView` performs its final filtering.
public func searchTitleMatchesQuery(_ title: String, query: String) -> Bool {
    let normalizedQuery = query
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .replacingOccurrences(of: #"[^a-z0-9\s]+"#, with: " ", options: [.regularExpression])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedTitle = title
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .replacingOccurrences(of: #"[^a-z0-9\s]+"#, with: " ", options: [.regularExpression])
        .trimmingCharacters(in: .whitespacesAndNewlines)

    let tokens = normalizedQuery
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
    guard !tokens.isEmpty else { return true }
    if tokens.allSatisfy({ normalizedTitle.contains($0) }) {
        return true
    }

    let compactQuery = normalizedQuery.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: [.regularExpression])
    guard compactQuery.count >= 3 else { return false }
    let compactTitle = normalizedTitle.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: [.regularExpression])
    return compactTitle.contains(compactQuery)
}
