@testable import TorraviaSearchCore
import AppKit
import Foundation
import Testing
@testable import Torravia

private actor DetailResolutionProbe {
    private var continuations: [Int: CheckedContinuation<Int?, Never>] = [:]
    private var starts = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var peakActive = 0
    func resolve(_ value: Int) async -> Int? {
        await withCheckedContinuation { continuation in
            continuations[value] = continuation; starts += 1; peakActive = max(peakActive, continuations.count)
            let ready = waiters.filter { starts >= $0.0 }; waiters.removeAll { starts >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForStarts(_ count: Int) async {
        if starts >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func complete(_ value: Int) { continuations.removeValue(forKey: value)?.resume(returning: value) }
}

@MainActor struct SearchDetailResolutionTests {
    @Test func detailResolutionBoundsConcurrencyAndPreservesInputOrder() async throws {
        let probe = DetailResolutionProbe()
        let task = Task { try await resolveSearchDetails(Array(0..<6), concurrency: 2) { await probe.resolve($0) } }
        await probe.waitForStarts(2)
        for value in 1..<5 { await probe.complete(value); await probe.waitForStarts(value + 2) }
        await probe.complete(5); await probe.complete(0)
        #expect(try await task.value == Array(0..<6))
        #expect(await probe.peakActive == 2)
    }
}
