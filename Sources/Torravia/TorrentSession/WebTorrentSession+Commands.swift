import Foundation

extension WebTorrentSession {
    func addTorrent(id: String, input: String, destination: URL, contentRoot: URL? = nil, filePaths: [String] = [], seedOnly: Bool = false) async throws {
        try await ensureRunning()
        var command: [String: Any] = [
            "type": "add",
            "id": id,
            "input": input,
            "destination": destination.path
        ]
        if let contentRoot { command["contentRoot"] = contentRoot.path }
        if !filePaths.isEmpty { command["filePaths"] = filePaths }
        command["seedOnly"] = seedOnly
        try send(command: command)
    }

    @discardableResult
    func pauseTorrent(id: String) async -> Bool {
        await sendCommandIgnoringErrors(["type": "pause", "id": id], autoStart: false)
    }

    @discardableResult
    func resumeTorrent(id: String) async -> Bool {
        await resumeTorrent(id: id, input: nil, destination: nil)
    }

    @discardableResult
    func resumeTorrent(id: String, input: String?, destination: URL?, contentRoot: URL? = nil, filePaths: [String] = [], seedOnly: Bool = false) async -> Bool {
        var command: [String: Any] = ["type": "resume", "id": id]
        if let input, !input.isEmpty {
            command["input"] = input
        }
        if let destination {
            command["destination"] = destination.path
        }
        if let contentRoot { command["contentRoot"] = contentRoot.path }
        if !filePaths.isEmpty { command["filePaths"] = filePaths }
        command["seedOnly"] = seedOnly
        return await sendCommandIgnoringErrors(command, autoStart: true)
    }

    @discardableResult
    func cancelTorrent(id: String, deleteData: Bool) async -> Bool {
        await sendCommandIgnoringErrors([
            "type": "cancel",
            "id": id,
            "destroyData": deleteData
        ], autoStart: false)
    }

    @discardableResult
    func stopSeeding(id: String) async -> Bool {
        await sendCommandIgnoringErrors([
            "type": "stop",
            "id": id
        ], autoStart: false)
    }

    @discardableResult
    func forceStartTorrent(id: String) async -> Bool {
        await sendCommandIgnoringErrors(["type": "forceStart", "id": id], autoStart: true)
    }

    func setQueuePosition(id: String, top: Bool) async {
        _ = await sendCommandIgnoringErrors(["type": top ? "queueTop" : "queueBottom", "id": id], autoStart: true)
    }

    func requestPieceAvailability(id: String) async {
        _ = await sendCommandIgnoringErrors(["type": "getPieceAvailability", "id": id], autoStart: true)
    }

    func requestPieceInspection(id: String) async {
        _ = await sendCommandIgnoringErrors(["type": "getPieceInspection", "id": id], autoStart: true)
    }

    func moveQueuePosition(id: String, up: Bool) async {
        _ = await sendCommandIgnoringErrors(["type": up ? "queueUp" : "queueDown", "id": id], autoStart: true)
    }

    func forceRecheckTorrent(id: String) async {
        _ = await sendCommandIgnoringErrors(["type": "forceRecheck", "id": id], autoStart: true)
    }

    func setSequentialDownload(id: String, enabled: Bool) async {
        _ = await sendCommandIgnoringErrors(["type": "setSequential", "id": id, "enabled": enabled], autoStart: true)
    }

    func setFileSelection(id: String, selectedIndices: [Int]) async {
        _ = await sendCommandIgnoringErrors([
            "type": "setFileSelection", "id": id, "selectedIndices": selectedIndices
        ], autoStart: true)
    }

    func setFilePriority(id: String, index: Int, priority: Int) async {
        _ = await sendCommandIgnoringErrors([
            "type": "setFilePriority", "id": id, "index": index, "priority": priority
        ], autoStart: true)
    }

    func setFirstLastPiecePriority(id: String, enabled: Bool) async {
        _ = await sendCommandIgnoringErrors([
            "type": "setFirstLastPiecePriority", "id": id, "enabled": enabled
        ], autoStart: true)
    }

    func setTorrentLimits(id: String, downloadLimit: Int64, uploadLimit: Int64, maxUploads: Int) async {
        _ = await sendCommandIgnoringErrors([
            "type": "setTorrentLimits",
            "id": id,
            "downloadLimit": max(downloadLimit, 0),
            "uploadLimit": max(uploadLimit, 0),
            "maxUploads": max(maxUploads, 0)
        ], autoStart: true)
    }

    func setShareRatioPolicy(id: String, limit: Double?, action: Int,
                             seedingMinutes: Int? = nil, inactiveMinutes: Int? = nil,
                             seedingSeconds: Int64 = 0, inactiveSeconds: Int64 = 0) async {
        let normalizedLimit = limit.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        _ = await sendCommandIgnoringErrors([
            "type": "setShareRatioPolicy", "id": id, "limit": normalizedLimit,
            "action": action == 1 || action == 2 ? action : 0,
            "seedingTimeLimit": min(max(seedingMinutes ?? 0, 0), 5_256_000),
            "inactiveSeedingTimeLimit": min(max(inactiveMinutes ?? 0, 0), 5_256_000),
            "seedingSeconds": max(seedingSeconds, 0), "inactiveSeconds": max(inactiveSeconds, 0)
        ], autoStart: true)
    }

    func refreshDiscovery(id: String) async {
        _ = await sendCommandIgnoringErrors(["type": "getDiscovery", "id": id], autoStart: true)
    }

    func reannounce(id: String) async {
        _ = await sendCommandIgnoringErrors(["type": "reannounce", "id": id], autoStart: true)
    }

    func addTracker(id: String, url: String, tier: Int = 0) async {
        _ = await sendCommandIgnoringErrors([
            "type": "addTracker", "id": id, "url": url, "tier": max(tier, 0)
        ], autoStart: true)
    }

    func removeTracker(id: String, url: String) async {
        _ = await sendCommandIgnoringErrors([
            "type": "removeTracker", "id": id, "url": url
        ], autoStart: true)
    }

    func addWebSeed(id: String, url: String) async {
        _ = await sendCommandIgnoringErrors([
            "type": "addWebSeed", "id": id, "url": url
        ], autoStart: true)
    }

    func removeWebSeed(id: String, url: String) async {
        _ = await sendCommandIgnoringErrors([
            "type": "removeWebSeed", "id": id, "url": url
        ], autoStart: true)
    }

    func addPeer(id: String, address: String) async {
        _ = await sendCommandIgnoringErrors([
            "type": "addPeer", "id": id, "address": address
        ], autoStart: true)
    }

    func banPeer(id: String, address: String) async {
        _ = await sendCommandIgnoringErrors(["type": "banPeer", "id": id, "address": address], autoStart: true)
    }

    func renameFile(id: String, index: Int, path: String) async {
        _ = await sendCommandIgnoringErrors([
            "type": "renameFile", "id": id, "index": index, "path": path
        ], autoStart: true)
    }

    func setPeerDetailsEnabled(_ enabled: Bool, id: String) async {
        _ = await sendCommandIgnoringErrors([
            "type": "setPeerDetails",
            "id": id,
            "enabled": enabled
        ], autoStart: enabled)
    }

    func shutdownAndWait() async {
        let runningProcess = process
        await shutdown()
        for _ in 0..<200 {
            guard runningProcess?.isRunning == true else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        runningProcess?.terminate()
    }

    @discardableResult
    func shutdown() async -> Bool {
        let success = await sendCommandIgnoringErrors(["type": "shutdown"], autoStart: false)
        await stopProcess()
        return success
    }

    func sendCommandIgnoringErrors(_ command: [String: Any], autoStart: Bool) async -> Bool {
        do {
            if autoStart {
                try await ensureRunning()
            } else if process?.isRunning != true {
                return false
            }
            try send(command: command)
            return true
        } catch {
            await emit(.error(id: command["id"] as? String, message: error.localizedDescription))
            return false
        }
    }
}
