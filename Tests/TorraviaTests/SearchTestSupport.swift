@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

struct StaticSearchProvider: TorrentSearchProviding {
    let items: [TorrentItem]

    func search(query _: String) async throws -> [TorrentItem] {
        items
    }
}

/// Intentionally ignores cancellation until released, like a provider that
/// is stuck in a resolver. The aggregator must not wait for it to unwind.
@MainActor
final class ControlledSearchProvider: TorrentSearchProviding {
    private var continuation: CheckedContinuation<[TorrentItem], Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false

    func search(query: String) async throws -> [TorrentItem] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started = true
            for waiter in startWaiters { waiter.resume() }
            startWaiters = []
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func complete(with items: [TorrentItem]) {
        continuation?.resume(returning: items)
        continuation = nil
    }
}

actor ControlledPeerLookup {
    private var pending: [CheckedContinuation<TrackerPeerEstimate?, Never>] = []
    private(set) var calls = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func lookup(_ magnet: String) async -> TrackerPeerEstimate? {
        calls += 1
        return await withCheckedContinuation { continuation in
            pending.append(continuation)
            for (_, waiter) in waiters.filter({ $0.0 <= calls }) { waiter.resume() }
            waiters.removeAll { $0.0 <= calls }
        }
    }

    func waitForCalls(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func completeAll(_ estimate: TrackerPeerEstimate?) {
        let current = pending
        pending = []
        current.forEach { $0.resume(returning: estimate) }
    }
}
