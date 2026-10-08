import Foundation

extension WebTorrentSession {
    func handle(stdoutLine line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendLog("[stdout] \(trimmed)")

        guard let data = trimmed.data(using: .utf8) else {
            appendLog("[stdout] Ignoring helper output that is not valid UTF-8")
            return
        }

        do {
            let message = try decoder.decode(HelperMessage.self, from: data)
            await handle(message: message)
        } catch {
            appendLog("[stdout] Ignoring malformed helper message: \(Self.decodingErrorDescription(error))")
        }
    }

    func consumeStdout(_ data: Data) async {
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[..<newlineIndex]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            guard let line = String(data: lineData, encoding: .utf8) else {
                appendLog("[stdout] Ignoring invalid UTF-8 helper message")
                continue
            }
            await handle(stdoutLine: line)
        }
    }

    func consumeStderr(_ data: Data) async {
        stderrBuffer.append(data)
        while let newlineIndex = stderrBuffer.firstIndex(of: 0x0A) {
            let lineData = stderrBuffer[..<newlineIndex]
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            guard let line = String(data: lineData, encoding: .utf8) else {
                await emit(.error(id: nil, message: "Invalid UTF-8 from helper stderr"))
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            appendLog("[stderr] \(trimmed)")
            bufferStderrLine(trimmed)
        }
    }

    func bufferStderrLine(_ line: String) {
        stderrPendingLines.append(line)
        stderrFlushTask?.cancel()
        stderrFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.stderrAggregationDelay)
            } catch {
                return
            }
            await self?.flushStderrLines()
        }
    }

    func flushStderrLines() async {
        stderrFlushTask?.cancel()
        stderrFlushTask = nil
        guard !stderrPendingLines.isEmpty else { return }
        let lines = stderrPendingLines
        stderrPendingLines.removeAll(keepingCapacity: false)
        let message = lines.joined(separator: "\n")
        await emit(.error(id: nil, message: message))
    }
}
