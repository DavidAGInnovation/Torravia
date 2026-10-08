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
    nonisolated(unsafe) private static var proxyDirectories: [ObjectIdentifier: [URL: URL]] = [:]
    public static func register(session: URLSession, observer: @escaping @Sendable (URLRequest, Data, URLResponse) -> Void) {
        lock.lock(); defer { lock.unlock() }
        observers[ObjectIdentifier(session)] = observer
        proxyDirectories[ObjectIdentifier(session)] = [:]
    }
    public static func unregister(session: URLSession) {
        lock.lock(); defer { lock.unlock() }
        observers.removeValue(forKey: ObjectIdentifier(session))
        proxyDirectories.removeValue(forKey: ObjectIdentifier(session))
    }
    /// Record only endpoints actually selected from a published proxy directory.
    /// Ordinary searches do not retain this metadata; it is scoped to a probe.
    public static func recordProxySelection(session: URLSession, directoryURL: URL, sourceURL: URL) {
        guard let origin = sourceOrigin(sourceURL) else { return }
        lock.lock(); defer { lock.unlock() }
        let id = ObjectIdentifier(session)
        guard observers[id] != nil else { return }
        proxyDirectories[id, default: [:]][origin] = directoryURL
    }
    public static func proxyDirectory(session: URLSession, for sourceURL: URL) -> URL? {
        guard let origin = sourceOrigin(sourceURL) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return proxyDirectories[ObjectIdentifier(session)]?[origin]
    }
    private static func sourceOrigin(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }
    public static func record(session: URLSession, request: URLRequest, data: Data, response: URLResponse) {
        lock.lock(); let observer = observers[ObjectIdentifier(session)]; lock.unlock()
        observer?(request, data, response)
    }
}
