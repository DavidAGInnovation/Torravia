import TorraviaSearchCore
import Foundation

struct ProviderFailure {
    let name: String
    let underlying: Error
}

private struct ProviderTimeoutError: LocalizedError {
    let provider: String
    let timeout: Double

    var errorDescription: String? {
        "\(provider) did not respond within \(Int(timeout.rounded())) seconds."
    }
}

enum ProviderOutcome {
    case success(String, [TorrentItem])
    case failure(ProviderFailure)
}

func outcome(for entry: SearchProvider.NamedProvider, query: String, timeout: Double) async -> ProviderOutcome? {
    let gate = ProviderOutcomeGate()

    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            gate.install(continuation)
            guard !Task.isCancelled else {
                gate.cancel()
                return
            }

            let providerTask = Task {
                do {
                    let items = try await searchProviderWithRetry(entry.provider, query: query)
                    gate.finish(.success(entry.name, items))
                } catch {
                    gate.finish(.failure(ProviderFailure(name: entry.name, underlying: error)))
                }
            }
            gate.setProviderTask(providerTask)

            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    gate.finish(.failure(ProviderFailure(
                        name: entry.name,
                        underlying: ProviderTimeoutError(provider: entry.name, timeout: timeout)
                    )))
                } catch {
                    // The provider completed first and cancelled this timer.
                }
            }
            gate.setTimeoutTask(timeoutTask)
        }
    } onCancel: {
        gate.cancel()
    }
}

private func searchProviderWithRetry(
    _ provider: any TorrentSearchProviding,
    query: String
) async throws -> [TorrentItem] {
    var lastError: Error?

    for attempt in 0..<2 {
        try Task.checkCancellation()
        do {
            return try await provider.search(query: query)
        } catch {
            lastError = error
            guard attempt == 0, isRetryableProviderError(error) else {
                throw error
            }
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                throw error
            }
        }
    }

    throw lastError ?? URLError(.unknown)
}

private func isRetryableProviderError(_ error: Error) -> Bool {
    if let statusError = error as? HTTPStatusError {
        return statusError.statusCode == 408
            || statusError.statusCode == 425
            || statusError.statusCode >= 500
    }

    let code = (error as NSError).code
    let transientURLCodes: Set<Int> = [
        URLError.timedOut.rawValue,
        URLError.cannotConnectToHost.rawValue,
        URLError.networkConnectionLost.rawValue,
        URLError.notConnectedToInternet.rawValue,
        URLError.dnsLookupFailed.rawValue
    ]
    return transientURLCodes.contains(code)
}

/// Races a provider request against its timeout without making the timeout
/// task wait for a slow URLSession child at the end of a structured task group.
/// The previous task-group implementation received the timeout's `nil` value
/// but then kept waiting for the provider, so the advertised timeout was never
/// actually enforced.
nonisolated private final class ProviderOutcomeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProviderOutcome?, Never>?
    private var providerTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false

    func install(_ continuation: CheckedContinuation<ProviderOutcome?, Never>) {
        lock.lock()
        if completed {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setProviderTask(_ task: Task<Void, Never>) {
        lock.lock()
        if completed {
            lock.unlock()
            task.cancel()
            return
        }
        providerTask = task
        lock.unlock()
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if completed {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    func cancel() {
        finish(nil)
    }

    func finish(_ outcome: ProviderOutcome?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        let providerTask = self.providerTask
        let timeoutTask = self.timeoutTask
        self.continuation = nil
        self.providerTask = nil
        self.timeoutTask = nil
        lock.unlock()

        providerTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(returning: outcome)
    }
}
