import Foundation

struct SearchTuning {
    let providerTimeoutSeconds: Double
    let maxResults: Int
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval
}

enum SearchMode {
    case fast
    case balanced

    var tuning: SearchTuning {
        switch self {
        case .fast:
            return SearchTuning(
                // A provider search is often more than one request: result
                // pages are followed by detail pages to resolve magnets. A
                // three-second wall clock timeout (the old value) therefore
                // discarded healthy providers as soon as an index got a bit
                // slower. Keep the fast mode bounded, but allow one normal
                // result + detail round trip to finish.
                providerTimeoutSeconds: 12,
                maxResults: 40,
                requestTimeout: 12,
                resourceTimeout: 24
            )
        case .balanced:
            return SearchTuning(
                // Provider implementations may resolve dozens of detail
                // pages sequentially. Four seconds made the search return an
                // empty list whenever the quickest index was unavailable,
                // even though another configured index had valid results.
                providerTimeoutSeconds: 20,
                maxResults: 60,
                requestTimeout: 15,
                resourceTimeout: 30
            )
        }
    }
}
