import Foundation

@MainActor public protocol TorrentSearchProviding {
    func search(query: String) async throws -> [TorrentItem]
}

/// An optional provider-owned request context; the public app needs none.
@MainActor public protocol ProviderRequestContext: AnyObject {}

public protocol SearchRateLimitError: LocalizedError {
    var retryAt: Date { get }
}
