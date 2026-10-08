import Foundation

actor WebTorrentSession {

    static let shared = WebTorrentSession()

    var process: Process?
    var stdinPipe: Pipe?
    var stdoutPipe: Pipe?
    var stderrPipe: Pipe?

    let decoder = JSONDecoder()

    var eventContinuation: AsyncStream<Event>.Continuation?
    lazy var eventStreamBacking: AsyncStream<Event> = {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }()

    var isReady = false
    var readyContinuations: [CheckedContinuation<Void, Error>] = []
    var terminationObserver: NSObjectProtocol?

    var helperContext: HelperContext?
    var logFileURL: URL?
    var logFileHandle: FileHandle?
    var stdoutBuffer = Data()
    var stderrBuffer = Data()
    var stdoutContinuation: AsyncStream<Data>.Continuation?
    var stderrContinuation: AsyncStream<Data>.Continuation?
    var stdoutReaderTask: Task<Void, Never>?
    var stderrReaderTask: Task<Void, Never>?
    var stderrPendingLines: [String] = []
    var stderrFlushTask: Task<Void, Never>?
    var networkConfiguration: NetworkConfiguration?

    static let stderrAggregationDelay: UInt64 = 150_000_000

    func eventsStream() -> AsyncStream<Event> {
        eventStreamBacking
    }

    func currentLogFileURL() async -> URL? {
        logFileURL
    }

    func applyNetworkConfiguration(_ configuration: NetworkConfiguration) async {
        networkConfiguration = configuration
        guard process?.isRunning == true, isReady else { return }
        try? sendNetworkConfiguration(configuration)
    }
}
