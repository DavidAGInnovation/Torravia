import Foundation

/// Resolve only the pages that contain missing torrent data. Keep request
/// concurrency bounded and preserve listing order regardless of completion order.
@MainActor
public func resolveSearchDetails<Input: Sendable, Output: Sendable>(
    _ inputs: [Input], concurrency: Int = 4,
    operation: @escaping @MainActor @Sendable (Input) async throws -> Output?
) async throws -> [Output] {
    try Task.checkCancellation()
    return try await withThrowingTaskGroup(of: (Int, Output?).self) { group in
        var iterator = inputs.enumerated().makeIterator()
        for _ in 0..<max(1, concurrency) {
            guard let (index, input) = iterator.next() else { break }
            group.addTask { @MainActor in (index, try await operation(input)) }
        }
        var results: [Int: Output] = [:]
        for try await (index, output) in group {
            try Task.checkCancellation()
            if let output { results[index] = output }
            if let (nextIndex, input) = iterator.next() {
                group.addTask { @MainActor in (nextIndex, try await operation(input)) }
            }
        }
        return results.keys.sorted().compactMap { results[$0] }
    }
}
