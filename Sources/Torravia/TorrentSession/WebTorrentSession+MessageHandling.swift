import Foundation

extension WebTorrentSession {
    func handle(message: HelperMessage) async {
        switch message.type {
        case "ready":
            isReady = true
            if let networkConfiguration {
                try? sendNetworkConfiguration(networkConfiguration)
            }
            readyContinuations.forEach { $0.resume(returning: ()) }
            readyContinuations.removeAll()
            await emit(.ready)
        case "added":
            guard let id = message.id,
                  let name = message.name,
                  let infoHash = message.infoHash,
                  let path = message.path,
                  let length = message.length
            else {
                await emit(.error(id: message.id, message: "Malformed added message"))
                return
            }
            let files = message.files?.map { Event.File(name: $0.name, length: $0.length ?? 0, isPadding: $0.isPadding ?? false) } ?? []
            let metainfo = message.metainfo.flatMap { Data(base64Encoded: $0) }
            await emit(.added(Event.Added(
                id: id,
                name: name,
                infoHash: infoHash,
                path: URL(fileURLWithPath: path),
                length: length,
                files: files,
                connectablePeers: max(message.connectablePeers ?? message.numPeers ?? 0, 0),
                connectedSeeders: max(message.connectedSeeders ?? 0, 0),
                connectedLeechers: max(message.connectedLeechers ?? 0, 0),
                knownPeers: max(message.knownPeers ?? message.numPeers ??
                                ((message.knownSeeders ?? message.connectedSeeders ?? 0) +
                                 (message.knownLeechers ?? message.connectedLeechers ?? 0)), 0),
                knownSeeders: max(message.knownSeeders ?? message.connectedSeeders ?? 0, 0),
                knownLeechers: max(message.knownLeechers ?? message.connectedLeechers ?? 0, 0),
                swarmSeeders: message.swarmSeeders.map { max($0, 0) },
                swarmLeechers: message.swarmLeechers.map { max($0, 0) },
                metainfo: metainfo
            )))
        case "progress":
            guard let id = message.id,
                  let progress = message.progress,
                  let downloadSpeed = message.downloadSpeed,
                  let uploadSpeed = message.uploadSpeed,
                  let downloaded = message.downloaded,
                  let uploaded = message.uploaded,
                  let numPeers = message.numPeers,
                  let path = message.path
            else {
                await emit(.error(id: message.id, message: "Malformed progress message"))
                return
            }
            let remaining = message.timeRemaining.map { $0 / 1000.0 }
            await emit(.progress(Event.Progress(
                id: id,
                progress: progress,
                downloadSpeed: downloadSpeed,
                uploadSpeed: uploadSpeed,
                downloaded: Int64(downloaded),
                uploaded: Int64(uploaded),
                isQueued: message.isQueued ?? false,
                numPeers: numPeers,
                connectablePeers: max(message.connectablePeers ?? numPeers, 0),
                connectedSeeders: max(message.connectedSeeders ?? 0, 0),
                connectedLeechers: max(message.connectedLeechers ?? 0, 0),
                knownPeers: max(message.knownPeers ?? message.numPeers ??
                                ((message.knownSeeders ?? message.connectedSeeders ?? 0) +
                                 (message.knownLeechers ?? message.connectedLeechers ?? 0)), 0),
                knownSeeders: max(message.knownSeeders ?? message.connectedSeeders ?? 0, 0),
                knownLeechers: max(message.knownLeechers ?? message.connectedLeechers ?? 0, 0),
                diskBacklogBytes: max(message.diskBacklogBytes ?? 0, 0),
                diskQueueLimitBytes: max(message.diskQueueLimitBytes ?? 0, 0),
                diskQueueWarnings: max(message.diskQueueWarnings ?? 0, 0),
                schedulerRank: message.schedulerRank ?? -1,
                swarmSeeders: message.swarmSeeders.map { max($0, 0) },
                swarmLeechers: message.swarmLeechers.map { max($0, 0) },
                timeRemaining: remaining,
                path: URL(fileURLWithPath: path),
                isProgressReady: message.isProgressReady ?? true,
                isFinished: message.isFinished ?? false,
                seedingTimeSeconds: message.seedingTimeSeconds ?? 0,
                inactiveSeedingTimeSeconds: message.inactiveSeedingTimeSeconds ?? 0
            )))
        case "done":
            guard let id = message.id, let path = message.path else {
                await emit(.error(id: message.id, message: "Malformed done message"))
                return
            }
            let files = message.files?.map { Event.File(name: $0.name, length: $0.length ?? 0, isPadding: $0.isPadding ?? false) } ?? []
            await emit(.done(Event.Completed(id: id, path: URL(fileURLWithPath: path), files: files)))
        case "networkStatus":
            guard let listenPort = message.listenPort,
                  let isListening = message.isListening,
                  let listenState = message.listenState,
                  let connectionLimit = message.connectionLimit,
                  let engineVersion = message.engineVersion,
                  let upnpStatus = message.upnpStatus,
                  let natpmpStatus = message.natpmpStatus,
                  let trackerStatus = message.trackerStatus,
                  let trackerAnnounces = message.trackerAnnounces,
                  let trackerReplies = message.trackerReplies,
                  let trackerErrors = message.trackerErrors,
                  let dhtStatus = message.dhtStatus,
                  let dhtReplies = message.dhtReplies,
                  let dhtNodes = message.dhtNodes
            else {
                await emit(.error(id: nil, message: "Malformed network status message"))
                return
            }
            await emit(.networkStatus(Event.NetworkStatus(
                listenPort: max(listenPort, 0),
                isListening: isListening,
                listenState: listenState,
                connectionLimit: max(connectionLimit, 0),
                engineVersion: engineVersion,
                upnpStatus: upnpStatus,
                natpmpStatus: natpmpStatus,
                trackerStatus: trackerStatus,
                trackerAnnounces: max(trackerAnnounces, 0),
                trackerReplies: max(trackerReplies, 0),
                trackerErrors: max(trackerErrors, 0),
                alertsDropped: max(message.alertsDropped ?? 0, 0),
                lastTrackerURL: message.lastTrackerURL,
                lastTrackerError: message.lastTrackerError,
                dhtStatus: dhtStatus,
                dhtReplies: max(dhtReplies, 0),
                dhtNodes: max(dhtNodes, 0)
            )))
        case "peers":
            guard let id = message.id,
                  let availability = message.availability,
                  let peers = message.peers else {
                await emit(.error(id: message.id, message: "Malformed peer snapshot"))
                return
            }
            await emit(.peers(Event.PeerSnapshot(
                id: id,
                availability: max(availability, 0),
                peers: peers.map {
                    Event.Peer(
                        address: $0.address,
                        port: max($0.port, 0),
                        client: $0.client,
                        transport: $0.transport,
                        direction: $0.direction,
                        sources: $0.sources,
                        downloadSpeed: Int64(max($0.downloadSpeed, 0)),
                        uploadSpeed: Int64(max($0.uploadSpeed, 0)),
                        progress: min(max($0.progress, 0), 1),
                        isSeed: $0.isSeed
                    )
                }
            )))
        case "discovery":
            guard let id = message.id else {
                await emit(.error(id: nil, message: "Malformed discovery snapshot"))
                return
            }
            let trackers = (message.trackers ?? []).map {
                Event.DiscoverySnapshot.Tracker(
                    url: $0.url,
                    tier: max($0.tier, 0),
                    state: $0.state,
                    source: max($0.source, 0),
                    fails: max($0.fails, 0),
                    updating: $0.updating,
                    message: $0.message,
                    scrapeComplete: $0.scrapeComplete.flatMap { $0 >= 0 ? $0 : nil },
                    scrapeIncomplete: $0.scrapeIncomplete.flatMap { $0 >= 0 ? $0 : nil }
                )
            }
            await emit(.discovery(Event.DiscoverySnapshot(
                id: id,
                trackers: trackers,
                webSeeds: message.webSeeds ?? [],
                trackerPeers: message.trackerPeers.flatMap { $0 >= 0 ? $0 : nil }
            )))
        case "pieceAvailability":
            guard let id = message.id else {
                await emit(.error(id: nil, message: "Malformed piece availability snapshot"))
                return
            }
            await emit(.pieceAvailability(Event.PieceAvailability(
                id: id,
                pieces: (message.pieces ?? []).map { max($0, 0) }
            )))
        case "pieceInspection":
            guard let id = message.id else {
                await emit(.error(id: nil, message: "Malformed piece inspection snapshot"))
                return
            }
            let files = (message.inspectionFiles ?? []).map {
                Event.PieceInspection.File(
                    index: $0.index,
                    name: $0.name,
                    length: max($0.length ?? 0, 0),
                    progress: min(max($0.progress ?? 0, 0), 1),
                    availability: max($0.availability ?? 0, 0),
                    priority: max($0.priority ?? 0, 0),
                    pieceStart: $0.pieceStart ?? -1,
                    pieceEnd: $0.pieceEnd ?? -1
                )
            }
            let pieces = (message.inspectionPieces ?? []).map {
                Event.PieceInspection.Piece(
                    index: $0.index,
                    have: $0.have,
                    availability: max($0.availability, 0),
                    priority: max($0.priority, 0),
                    hash: $0.hash
                )
            }
            await emit(.pieceInspection(Event.PieceInspection(
                id: id,
                pieceLength: max(message.pieceLength ?? 0, 0),
                files: files,
                pieces: pieces
            )))
        case "paused":
            if let id = message.id { await emit(.paused(id: id)) }
        case "resumed":
            if let id = message.id { await emit(.resumed(id: id)) }
        case "cancelled":
            if let id = message.id { await emit(.cancelled(id: id)) }
        case "seedingStopped":
            if let id = message.id { await emit(.seedingStopped(id: id)) }
        case "seedingLimitReached":
            if let id = message.id {
                await emit(.seedingLimitReached(id: id, action: message.action ?? "pause", reason: message.reason ?? "time"))
            }
        case "shareRatioReached":
            if let id = message.id {
                await emit(.shareRatioReached(id: id, action: message.action ?? "pause"))
            }
        case "resumeRejected":
            if let id = message.id {
                await emit(.resumeRejected(
                    id: id,
                    message: message.message ?? "Saved download state could not be restored."
                ))
            }
        case "resumeRechecking":
            if let id = message.id {
                await emit(.resumeRechecking(
                    id: id,
                    message: message.message ?? "Saved download state was stale; verifying existing files."
                ))
            }
        case "warning":
            await emit(.warning(id: message.id, message: message.message ?? "Torrent engine adjusted its configuration."))
        case "storageError":
            if let id = message.id {
                await emit(.storageError(id: id, message: message.message ?? "The download storage is unavailable."))
            }
        case "noPeers":
            if let id = message.id { await emit(.noPeers(id: id, announceType: message.announceType)) }
        case "error":
            await emit(.error(id: message.id, message: message.message ?? "Unknown helper error"))
        default:
            await emit(.error(id: message.id, message: "Unhandled helper message type: \(message.type)"))
        }
    }

    func emit(_ event: Event) async {
        eventContinuation?.yield(event)
    }
}
