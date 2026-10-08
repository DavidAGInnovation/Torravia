import Foundation

extension WebTorrentSession {
    func ensureRunning() async throws {
        if let process, process.isRunning {
            if isReady { return }
        } else {
            try await startProcess()
        }

        if isReady { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyContinuations.append(continuation)
        }
    }

    func startProcess() async throws {
        if process?.isRunning == true { return }

        let context = try prepareHelperContext()
        guard let helperURL = Self.bundledHelperExecutableURL() else {
            throw HelperError.helperMissing
        }

        closeLogFile()
        let (logURL, logHandle) = try Self.makeLogFile(in: context.directory)
        logFileURL = logURL
        logFileHandle = logHandle
        appendLog("Launching native torrent helper")

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        stdinPipe = inputPipe
        stdoutPipe = outputPipe
        stderrPipe = errorPipe

        let process = Process()
        process.executableURL = helperURL
        process.arguments = []
        process.currentDirectoryURL = context.directory
        var environment = ProcessInfo.processInfo.environment
        if let diskIOBackend = networkConfiguration?.diskIOBackend {
            // The disk backend is selected when libtorrent constructs its
            // session. Runtime cache/queue settings still apply immediately;
            // changing the backend takes effect on the next helper launch.
            environment["TORRAVIA_DISK_IO_BACKEND"] = diskIOBackend
        }
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw HelperError.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.isReady = false
        appendLog("native helper started (pid: \(process.processIdentifier))")

        stdoutBuffer.removeAll(keepingCapacity: true)
        stderrBuffer.removeAll(keepingCapacity: true)

        let stdoutStream = AsyncStream<Data>.makeStream()
        let stderrStream = AsyncStream<Data>.makeStream()
        stdoutContinuation = stdoutStream.continuation
        stderrContinuation = stderrStream.continuation

        stdoutReaderTask = Task { [weak self] in
            for await data in stdoutStream.stream {
                await self?.consumeStdout(data)
            }
            await self?.appendLog("[stdout] EOF")
        }
        stderrReaderTask = Task { [weak self] in
            for await data in stderrStream.stream {
                await self?.consumeStderr(data)
            }
            await self?.flushStderrLines()
            await self?.appendLog("[stderr] EOF")
        }

        let stdoutContinuation = stdoutStream.continuation
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stdoutContinuation.finish()
                handle.readabilityHandler = nil
            } else {
                stdoutContinuation.yield(data)
            }
        }

        let stderrContinuation = stderrStream.continuation
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                stderrContinuation.finish()
                handle.readabilityHandler = nil
            } else {
                stderrContinuation.yield(data)
            }
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: Process.didTerminateNotification,
            object: process,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let proc = notification.object as? Process
            Task { await self.handleTermination(for: proc) }
        }
    }

    func stopProcess() async {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        stdoutContinuation?.finish()
        stderrContinuation?.finish()
        let stdoutReaderTask = stdoutReaderTask
        let stderrReaderTask = stderrReaderTask
        self.stdoutContinuation = nil
        self.stderrContinuation = nil
        self.stdoutReaderTask = nil
        self.stderrReaderTask = nil
        await stdoutReaderTask?.value
        await stderrReaderTask?.value

        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
            terminationObserver = nil
        }

        process = nil
        isReady = false
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)

        if let stdinPipe {
            try? stdinPipe.fileHandleForWriting.close()
        }
        if let stdoutPipe {
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
        }
        if let stderrPipe {
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
        }

        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        await flushStderrLines()
        closeLogFile()
    }

    func handleTermination(for process: Process?) async {
        guard let process else { return }
        appendLog("native helper exited with code \(process.terminationStatus)")
        if !isReady {
            readyContinuations.forEach { $0.resume(throwing: HelperError.processTerminated) }
            readyContinuations.removeAll()
        }
        await emit(.stopped(code: process.terminationStatus))
        await stopProcess()
    }
}
