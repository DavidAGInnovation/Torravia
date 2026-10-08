import Foundation

public extension URLSession {
    func providerData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let result = try await data(for: request)
        ProviderSearchProbeRegistry.record(session: self, request: request, data: result.0, response: result.1)
        return result
    }
    func providerData(from url: URL) async throws -> (Data, URLResponse) {
        try await providerData(for: URLRequest(url: url))
    }
}

/// Observations are scoped to a probe session, never to ordinary search sessions.
nonisolated public enum ProviderSearchProbeRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var observers: [ObjectIdentifier: @Sendable (URLRequest, Data, URLResponse) -> Void] = [:]
    public static func register(session: URLSession, observer: @escaping @Sendable (URLRequest, Data, URLResponse) -> Void) {
        lock.lock(); defer { lock.unlock() }
        observers[ObjectIdentifier(session)] = observer
    }
    public static func unregister(session: URLSession) {
        lock.lock(); defer { lock.unlock() }
        observers.removeValue(forKey: ObjectIdentifier(session))
    }
    public static func record(session: URLSession, request: URLRequest, data: Data, response: URLResponse) {
        lock.lock(); let observer = observers[ObjectIdentifier(session)]; lock.unlock()
        observer?(request, data, response)
    }
}
