//
//  DownloadsViewModel+RemoteControlPayloads.swift
//  Torravia
//
//  Payload construction and mutation helpers for the authenticated local API.
//

import Foundation
import Network

@MainActor
extension DownloadsViewModel {
    func remoteToken(from components: URLComponents, headerLines: [String]) -> String? {
        if let token = components.queryItems?.first(where: { $0.name == "token" })?.value {
            return token
        }
        for line in headerLines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Authorization") == .orderedSame else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("bearer ") {
                return String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    func sendRemoteJSON(_ object: Any, status: String = "200 OK", connection: NWConnection?) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        sendRemoteResponse(status: status,
                           contentType: "application/json",
                           body: String(data: data, encoding: .utf8) ?? "{}",
                           connection: connection)
    }

    func persistManagedCatalogs() {
        UserDefaults.standard.set(managedCategoryPaths, forKey: Self.managedCategoryPathsKey)
        UserDefaults.standard.set(Array(managedTags).sorted(), forKey: Self.managedTagsKey)
    }

    func managedCategoryNames() -> [String] {
        let downloadCategories = downloads.map(\.category).filter { !$0.isEmpty }
        return Array(Set(downloadCategories + Array(managedCategoryPaths.keys))).sorted()
    }

    func managedTagNames() -> [String] {
        let downloadTags = downloads.flatMap(\.tags)
        let ruleTags = automation.rssRules.flatMap(\.tags)
        return Array(Set(downloadTags + ruleTags + Array(managedTags))).sorted()
    }

    func remoteCategoriesPayload() -> [[String: Any]] {
        managedCategoryNames().map { name in
            ["name": name, "savePath": managedCategoryPaths[name] ?? ""]
        }
    }

    func remoteTagsPayload() -> [String] {
        managedTagNames()
    }

    func applyRemoteDownloadOptions(_ body: [String: Any], to download: Download) {
        if let category = body["category"] as? String {
            let tags: [String]
            if let values = body["tags"] as? [String] {
                tags = values
            } else if let value = body["tags"] as? String {
                tags = value.split(separator: ",").map(String.init)
            } else {
                tags = download.tags
            }
            updateMetadata(for: download.id, category: category, tags: tags)
        } else if let values = body["tags"] as? [String] {
            updateMetadata(for: download.id, category: download.category, tags: values)
        }
        if let sequential = body["sequential"] as? Bool {
            setSequentialDownload(sequential, for: download)
        }
        if let firstLast = body["firstLastPiecePriority"] as? Bool {
            setFirstLastPiecePriority(firstLast, for: download)
        }
        let downloadLimit = (body["downloadLimit"] as? NSNumber)?.int64Value
        let uploadLimit = (body["uploadLimit"] as? NSNumber)?.int64Value
        let maxUploads = (body["maxUploads"] as? NSNumber)?.intValue
        if downloadLimit != nil || uploadLimit != nil || maxUploads != nil {
            setTorrentLimits(for: download,
                             downloadLimit: downloadLimit,
                             uploadLimit: uploadLimit,
                             maxUploads: maxUploads)
        }
        if ["shareRatioLimit", "shareRatioAction", "seedingTimeLimitMinutes", "inactiveSeedingTimeLimitMinutes"].contains(where: body.keys.contains) {
            setSeedingPolicy(for: download.id,
                ratioLimit: body.keys.contains("shareRatioLimit") ? (body["shareRatioLimit"] as? NSNumber)?.doubleValue : download.shareRatioLimit,
                seedingMinutes: body.keys.contains("seedingTimeLimitMinutes") ? (body["seedingTimeLimitMinutes"] as? NSNumber)?.intValue : download.seedingTimeLimitMinutes,
                inactiveMinutes: body.keys.contains("inactiveSeedingTimeLimitMinutes") ? (body["inactiveSeedingTimeLimitMinutes"] as? NSNumber)?.intValue : download.inactiveSeedingTimeLimitMinutes,
                action: (body["shareRatioAction"] as? String).flatMap(Download.ShareRatioAction.init(rawValue:)) ?? download.shareRatioAction)
        }
        if let priority = (body["queuePriority"] as? NSNumber)?.intValue {
            setQueuePriority(priority, for: download)
        }
        if let forceStarted = body["forceStarted"] as? Bool {
            if forceStarted { forceStart(download) } else { resume(download) }
        }
        if let selected = body["selectedFileIndices"] as? [Int] {
            update(downloadID: download.id) { $0.selectedFileIndices = Set(selected) }
            Task(priority: .userInitiated) { [session] in
                await session.setFileSelection(id: download.id.uuidString, selectedIndices: selected.sorted())
            }
        }
    }

    func remoteDownloadProperties(_ download: Download) -> [String: Any] {
        var payload = remoteDownloadsPayload().first(where: { ($0["id"] as? String) == download.id.uuidString }) ?? [:]
        payload["infoHash"] = download.infoHash ?? ""
        payload["destination"] = download.destinationURL?.path ?? ""
        payload["storage"] = download.storageURL?.path ?? ""
        payload["torrentFile"] = download.torrentFileName ?? ""
        payload["selectedFileIndices"] = Array((download.selectedFileIndices ?? Set(download.files.indices)).sorted())
        payload["filePriorities"] = download.filePriorities ?? download.files.indices.map { download.selectedFileIndices?.contains($0) == false ? 0 : 4 }
        payload["firstLastPiecePriority"] = download.firstLastPiecePriority
        payload["shareRatioAction"] = download.shareRatioAction.rawValue
        payload["seedingTimeLimitMinutes"] = download.seedingTimeLimitMinutes ?? 0
        payload["inactiveSeedingTimeLimitMinutes"] = download.inactiveSeedingTimeLimitMinutes ?? 0
        payload["seedingTimeSeconds"] = download.seedingTimeSeconds
        payload["inactiveSeedingTimeSeconds"] = download.inactiveSeedingTimeSeconds
        payload["files"] = download.files.enumerated().map { index, file in
            ["index": index,
             "name": file.relativePath,
             "length": file.length,
             "selected": download.selectedFileIndices?.contains(index) ?? true,
             "priority": download.filePriorities?.indices.contains(index) == true ? download.filePriorities![index] : 4]
        }
        return payload
    }

    func remoteRSSPayload() -> [[String: Any]] {
        automation.rssRules.map { rule in
            let states = rule.feedURLs.compactMap { rssFeedStates[$0] }
            let state = states.sorted { ($0.lastPolledAt ?? .distantPast) > ($1.lastPolledAt ?? .distantPast) }.first
            return ["id": rule.id.uuidString,
             "feedURL": rule.feedURL,
             "feedURLs": rule.feedURLs,
             "name": rule.name,
             "episodeFilter": rule.episodeFilter,
             "smartEpisodeFilter": rule.smartEpisodeFilter,
             "downloadRepacks": rule.downloadRepacks,
             "ignoreDays": rule.ignoreDays,
             "previouslyMatchedEpisodes": rule.previouslyMatchedEpisodes.sorted(),
             "lastMatch": rule.lastMatch.map { $0.timeIntervalSince1970 } ?? NSNull(),
             "include": rule.include,
             "exclude": rule.exclude,
             "category": rule.category,
             "enabled": rule.enabled,
             "matchAll": rule.matchAll,
             "maxItemsPerPoll": rule.maxItemsPerPoll,
             "tags": rule.tags,
             "startPaused": rule.startPaused,
             "sequential": rule.sequential,
             "queuePriority": rule.queuePriority,
             "lastPolledAt": state?.lastPolledAt.map { $0.timeIntervalSince1970 } ?? NSNull(),
             "lastError": states.compactMap(\.lastError).first ?? NSNull(),
             "itemCount": states.reduce(0) { $0 + $1.itemCount },
             "importedCount": states.reduce(0) { $0 + $1.importedCount }]
        }
    }

    func remoteDownloadsPayload() -> [[String: Any]] {
        downloads.enumerated().map { position, download in
            let peerEstimate = download.displayedPeerEstimate
            let peerEstimateSource = download.hasTrackerSwarmEstimate ? "tracker" : "local"
            return ["id": download.id.uuidString,
             "title": download.title,
             "originalSearchTitle": download.originalSearchTitle ?? NSNull(),
             "status": download.status.rawValue,
             "category": download.category,
             "tags": download.tags,
             "progress": download.displayProgress,
             "downloadedBytes": download.downloadedBytes,
             "uploadedBytes": download.uploadedBytes,
             "totalBytes": download.resolvedSizeBytes,
             "downloadSpeed": download.speedBytesPerSec,
             "averageDownloadSpeed": download.averageSpeedBytesPerSec,
             "peakDownloadSpeed": download.peakSpeedBytesPerSec,
             "uploadSpeed": download.uploadSpeedBytesPerSec,
             "etaSeconds": download.etaSeconds ?? NSNull(),
             "connectedPeers": download.numPeers,
             "cachedPeers": download.cachedPeerCount,
             "knownPeers": download.knownPeerCount,
             "connectablePeers": download.connectablePeers,
             "swarmPeers": download.swarmPeerEstimate ?? NSNull(),
             "peerEstimate": peerEstimate,
             "peerEstimateSource": peerEstimateSource,
             "connectedSeeders": download.connectedSeeders,
             "connectedLeechers": download.connectedLeechers,
             "knownSeeders": download.knownSeeders,
             "knownLeechers": download.knownLeechers,
             "forceStarted": download.isForceStarted,
             "queuePosition": position,
             "queuePriority": download.queuePriority,
             "sequential": download.isSequentialDownload,
             "downloadLimit": download.downloadLimitBytesPerSec,
             "uploadLimit": download.uploadLimitBytesPerSec,
             "maxUploads": download.maxUploads,
             "shareRatioLimit": download.shareRatioLimit ?? NSNull(),
             "shareRatio": download.uploadedToDownloadedRatio ?? NSNull()]
        }
    }

    func remotePreferencesPayload() -> [String: Any] {
        let configuration = preferences.networkConfiguration
        return [
            "listenPort": configuration.listenPort,
            "globalConnectionLimit": configuration.globalConnectionLimit,
            "perTorrentConnectionLimit": configuration.perTorrentConnectionLimit,
            "downloadLimitBytesPerSecond": configuration.downloadLimitBytesPerSecond,
            "uploadLimitBytesPerSecond": configuration.uploadLimitBytesPerSecond,
            "globalUploadSlots": configuration.globalUploadSlots,
            "perTorrentUploadSlots": configuration.perTorrentUploadSlots,
            "queueingEnabled": configuration.queueingEnabled,
            "maximumActiveDownloads": configuration.maximumActiveDownloads,
            "maximumActiveSeeds": configuration.maximumActiveSeeds,
            "maximumActiveTorrents": configuration.maximumActiveTorrents,
            "ignoreSlowTorrents": configuration.ignoreSlowTorrents,
            "networkInterface": configuration.networkInterface,
            "transportMode": configuration.transportMode,
            "encryptionMode": configuration.encryptionMode,
            "outgoingPortStart": configuration.outgoingPortStart,
            "outgoingPortEnd": configuration.outgoingPortEnd,
            "additionalTrackerURLs": configuration.additionalTrackerURLs,
            "dhtEnabled": configuration.dhtEnabled,
            "peerExchangeEnabled": configuration.peerExchangeEnabled,
            "localPeerDiscoveryEnabled": configuration.localPeerDiscoveryEnabled,
            "upnpEnabled": configuration.upnpEnabled,
            "natpmpEnabled": configuration.natpmpEnabled,
            "proxyType": configuration.proxyType,
            "proxyHost": configuration.proxyHost,
            "proxyPort": configuration.proxyPort,
            "proxyPeerConnections": configuration.proxyPeerConnections,
            "proxyHostnames": configuration.proxyHostnames,
            "proxyTrackerConnections": configuration.proxyTrackerConnections,
            "anonymousMode": configuration.anonymousMode,
            "ssrfMitigationEnabled": configuration.ssrfMitigationEnabled,
            "validateHTTPSTrackers": configuration.validateHTTPSTrackers,
            "blockPrivilegedPeerPorts": configuration.blockPrivilegedPeerPorts,
            "allowMultipleConnectionsPerIP": configuration.allowMultipleConnectionsPerIP,
            "i2pEnabled": configuration.i2pEnabled,
            "i2pHost": configuration.i2pHost,
            "i2pPort": configuration.i2pPort,
            "i2pMixedMode": configuration.i2pMixedMode,
            "blockedIPRanges": configuration.blockedIPRanges,
            "downloadLimitMBps": preferences.downloadLimitMBps,
            "uploadLimitMBps": preferences.uploadLimitMBps,
            "bandwidthSchedule": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences.bandwidthSchedule))) ?? [:],
            "scheduledLimitsActive": preferences.bandwidthSchedule.isActive(at: Date())
        ]
    }

    func remotePeersPayload(for id: UUID) -> [String: Any] {
        let snapshot = peerSnapshots[id]
        let download = downloads.first(where: { $0.id == id })
        let connectedLimit = max(download?.numPeers ?? snapshot?.peers.count ?? 0, 0)
        let peers = snapshot?.peers.prefix(connectedLimit).map { peer in
            ["address": peer.address,
             "port": peer.port,
             "client": peer.client,
             "transport": peer.transport,
             "direction": peer.direction,
             "sources": peer.sources,
             "downloadSpeed": peer.downloadSpeed,
             "uploadSpeed": peer.uploadSpeed,
             "progress": peer.progress,
             "isSeed": peer.isSeed] as [String: Any]
        } ?? []
        let peerEstimate = download?.displayedPeerEstimate ?? 0
        let peerEstimateSource = download?.hasTrackerSwarmEstimate == true ? "tracker" : "local"
        return [
            "id": id.uuidString,
            "availability": snapshot?.availability ?? 0,
            "connected": peers.count,
            "cached": download?.cachedPeerCount ?? peers.count,
            "known": download?.knownPeerCount ?? peers.count,
            "connectable": download?.connectablePeers ?? 0,
            "swarmEstimate": download?.swarmPeerEstimate ?? NSNull(),
            "peerEstimate": peerEstimate,
            "peerEstimateSource": peerEstimateSource,
            "peers": peers,
            "refreshPending": snapshot == nil
        ]
    }

    func remoteDiscoveryPayload(for id: UUID) -> [String: Any] {
        let snapshot = discoverySnapshots[id]
        let trackers = snapshot?.trackers.map { tracker in
            ["url": tracker.url,
             "tier": tracker.tier,
             "state": tracker.state,
             "source": tracker.source,
             "fails": tracker.fails,
             "updating": tracker.updating,
             "message": tracker.message,
             "scrapeComplete": tracker.scrapeComplete ?? NSNull(),
             "scrapeIncomplete": tracker.scrapeIncomplete ?? NSNull()] as [String: Any]
        } ?? []
        return [
            "id": id.uuidString,
            "trackers": trackers,
            "webSeeds": snapshot?.webSeeds ?? [],
            "refreshPending": snapshot == nil
        ]
    }

    func remoteInspectionPayload(for id: UUID) -> [String: Any] {
        guard let inspection = pieceInspections[id] else {
            return ["id": id.uuidString, "pieceLength": 0, "files": [], "pieces": [], "refreshPending": true]
        }
        return [
            "id": id.uuidString,
            "pieceLength": inspection.pieceLength,
            "files": inspection.files.map {
                ["index": $0.index,
                 "name": $0.name,
                 "length": $0.length,
                 "progress": $0.progress,
                 "availability": $0.availability,
                 "priority": $0.priority,
                 "pieceStart": $0.pieceStart,
                 "pieceEnd": $0.pieceEnd] as [String: Any]
            },
            "pieces": inspection.pieces.map {
                ["index": $0.index,
                 "have": $0.have,
                 "availability": $0.availability,
                 "priority": $0.priority,
                 "hash": $0.hash] as [String: Any]
            },
            "refreshPending": false
        ]
    }

    func remoteDiagnosticsPayload(for download: Download) -> [String: Any] {
        let id = download.id
        let pieces = pieceAvailabilitySnapshots[id] ?? []
        return [
            "id": id.uuidString,
            "title": download.title,
             "originalSearchTitle": download.originalSearchTitle ?? NSNull(),
            "status": download.status.rawValue,
            "progress": download.displayProgress,
            "download": [
                "speed": download.speedBytesPerSec,
                "averageSpeed": download.averageSpeedBytesPerSec,
                "peakSpeed": download.peakSpeedBytesPerSec,
                "downloadedBytes": download.downloadedBytes,
                "totalBytes": download.resolvedSizeBytes,
                "etaSeconds": download.etaSeconds.map { $0 as Any } ?? NSNull()
            ],
            "network": [
                "listenPort": networkStatus?.listenPort ?? 0,
                "isListening": networkStatus?.isListening ?? false,
                "listenState": networkStatus?.listenState ?? "unknown",
                "dhtStatus": networkStatus?.dhtStatus ?? "unknown",
                "dhtNodes": networkStatus?.dhtNodes ?? 0,
                "trackerStatus": networkStatus?.trackerStatus ?? "unknown",
                "trackerReplies": networkStatus?.trackerReplies ?? 0,
                "trackerErrors": networkStatus?.trackerErrors ?? 0,
                "alertsDropped": networkStatus?.alertsDropped ?? 0
            ],
            "peers": remotePeersPayload(for: id),
            "discovery": remoteDiscoveryPayload(for: id),
            "pieces": [
                "values": pieces,
                "availablePieces": pieces.filter { $0 > 0 }.count,
                "pieceCount": pieces.count,
                "refreshPending": pieces.isEmpty
            ],
            "inspection": remoteInspectionPayload(for: id)
        ]
    }

    func applyRemotePreferences(_ values: [String: Any]) {
        func int(_ key: String, _ fallback: Int) -> Int? {
            if let value = values[key] as? Int { return value }
            if let value = values[key] as? NSNumber { return value.intValue }
            if let value = values[key] as? String, let parsed = Int(value) { return parsed }
            return fallback == 0 ? nil : fallback
        }
        func bool(_ key: String) -> Bool? {
            if let value = values[key] as? Bool { return value }
            if let value = values[key] as? NSNumber { return value.boolValue }
            if let value = values[key] as? String { return ["1", "true", "yes", "on"].contains(value.lowercased()) }
            return nil
        }
        func string(_ key: String) -> String? { values[key] as? String }

        if let schedule = values["bandwidthSchedule"] as? [String: Any] {
            var updated = preferences.bandwidthSchedule
            if let enabled = schedule["enabled"] as? Bool { updated.enabled = enabled }
            if let days = schedule["weekdays"] as? [Int] { updated.weekdays = Set(days.filter { (1...7).contains($0) }) }
            if let start = schedule["startMinute"] as? Int { updated.startMinute = min(max(start, 0), 1439) }
            if let end = schedule["endMinute"] as? Int { updated.endMinute = min(max(end, 0), 1439) }
            if let limit = schedule["downloadLimitMBps"] as? Int { updated.downloadLimitMBps = min(max(limit, 0), 1000) }
            if let limit = schedule["uploadLimitMBps"] as? Int { updated.uploadLimitMBps = min(max(limit, 0), 1000) }
            preferences.bandwidthSchedule = updated
        }
        if let value = int("listenPort", 0) { preferences.listenPort = min(max(value, 49_152), 65_535) }
        if let value = int("globalConnectionLimit", 0) { preferences.globalConnectionLimit = min(max(value, 50), 1_000) }
        if let value = int("perTorrentConnectionLimit", 0) { preferences.perTorrentConnectionLimit = min(max(value, 10), 500) }
        if let value = int("downloadLimitMBps", 0) { preferences.downloadLimitMBps = min(max(value, 0), 1_000) }
        if let value = int("uploadLimitMBps", 0) { preferences.uploadLimitMBps = min(max(value, 0), 1_000) }
        if let value = int("downloadLimitBytesPerSecond", 0) { preferences.downloadLimitMBps = min(max(value / 1_000_000, 0), 1_000) }
        if let value = int("uploadLimitBytesPerSecond", 0) { preferences.uploadLimitMBps = min(max(value / 1_000_000, 0), 1_000) }
        if let value = int("globalUploadSlots", 0) { preferences.globalUploadSlots = min(max(value, 1), 200) }
        if let value = int("perTorrentUploadSlots", 0) { preferences.perTorrentUploadSlots = min(max(value, 1), 50) }
        if let value = bool("queueingEnabled") { preferences.isQueueingEnabled = value }
        if let value = int("maximumActiveDownloads", 0) { preferences.maximumActiveDownloads = min(max(value, 1), 50) }
        if let value = int("maximumActiveSeeds", 0) { preferences.maximumActiveSeeds = min(max(value, 1), 50) }
        if let value = int("maximumActiveTorrents", 0) { preferences.maximumActiveTorrents = min(max(value, 1), 100) }
        if let value = bool("ignoreSlowTorrents") { preferences.ignoreSlowTorrents = value }
        if let value = string("networkInterface") { preferences.networkInterface = value }
        if let value = string("transportMode"), let mode = TorrentTransportMode(rawValue: value) { preferences.transportMode = mode }
        if let value = string("encryptionMode"), let mode = TorrentEncryptionMode(rawValue: value) { preferences.encryptionMode = mode }
        if let value = int("outgoingPortStart", 0) { preferences.outgoingPortStart = min(max(value, 0), 65_535) }
        if let value = int("outgoingPortEnd", 0) { preferences.outgoingPortEnd = min(max(value, 0), 65_535) }
        if let value = string("additionalTrackerURLs") { preferences.additionalTrackerURLs = value }
        if let value = bool("dhtEnabled") { preferences.isDHTEnabled = value }
        if let value = bool("peerExchangeEnabled") { preferences.isPeerExchangeEnabled = value }
        if let value = bool("localPeerDiscoveryEnabled") { preferences.isLocalPeerDiscoveryEnabled = value }
        if let value = bool("upnpEnabled") { preferences.isUPnPEnabled = value }
        if let value = bool("natpmpEnabled") { preferences.isNATPMPEnabled = value }
        if let value = string("proxyType"), let type = TorrentProxyType(rawValue: value) { preferences.proxyType = type }
        if let value = string("proxyHost") { preferences.proxyHost = value }
        if let value = int("proxyPort", 0) { preferences.proxyPort = min(max(value, 0), 65_535) }
        if let value = bool("proxyPeerConnections") { preferences.proxyPeerConnections = value }
        if let value = bool("proxyHostnames") { preferences.proxyHostnames = value }
        if let value = bool("proxyTrackerConnections") { preferences.proxyTrackerConnections = value }
        if let value = bool("anonymousMode") { preferences.anonymousMode = value }
        if let value = bool("ssrfMitigationEnabled") { preferences.ssrfMitigationEnabled = value }
        if let value = bool("validateHTTPSTrackers") { preferences.validateHTTPSTrackers = value }
        if let value = bool("blockPrivilegedPeerPorts") { preferences.blockPrivilegedPeerPorts = value }
        if let value = bool("allowMultipleConnectionsPerIP") { preferences.allowMultipleConnectionsPerIP = value }
        if let value = bool("i2pEnabled") { preferences.isI2PEnabled = value }
        if let value = string("i2pHost") { preferences.i2pHost = value }
        if let value = int("i2pPort", 0) { preferences.i2pPort = min(max(value, 1), 65_535) }
        if let value = bool("i2pMixedMode") { preferences.i2pMixedMode = value }
        if let value = string("blockedIPRanges") { preferences.blockedIPRanges = value }
    }

    func performRemoteAction(_ action: String,
                                     for download: Download,
                                     parameters: [String: Any]) {
        func string(_ key: String) -> String? {
            if let value = parameters[key] as? String { return value }
            return nil
        }
        func int(_ key: String) -> Int? {
            if let value = parameters[key] as? Int { return value }
            if let value = parameters[key] as? NSNumber { return value.intValue }
            return string(key).flatMap(Int.init)
        }
        switch action {
        case "pause": pause(download)
        case "resume": resume(download)
        case "forceStart": forceStart(download)
        case "cancel": cancel(download, deleteFiles: (parameters["deleteFiles"] as? Bool) ?? (string("deleteFiles") == "true"))
        case "queueTop": moveToTop(download)
        case "queueBottom": moveToBottom(download)
        case "moveUp": moveUp(download)
        case "moveDown": moveDown(download)
        case "forceRecheck": forceRecheck(download)
        case "stopSeeding": stopSeeding(download)
        case "refreshDiscovery": refreshDiscovery(for: download.id)
        case "reannounce": reannounce(for: download.id)
        case "addTracker":
            if let url = string("url") { addTracker(url, tier: int("tier") ?? 0, for: download.id) }
        case "removeTracker":
            if let url = string("url") { removeTracker(url, for: download.id) }
        case "addWebSeed":
            if let url = string("url") { addWebSeed(url, for: download.id) }
        case "removeWebSeed":
            if let url = string("url") { removeWebSeed(url, for: download.id) }
        case "addPeer":
            if let address = string("address") { addPeer(address, for: download.id) }
        case "banPeer":
            if let address = string("address") { banPeerAddress(address, for: download.id) }
        case "inspectPeers": setPeerInspectionEnabled(true, for: download.id)
        case "setShareRatio":
            let ratio = (parameters["limit"] as? Double) ?? string("limit").flatMap(Double.init)
            let ratioAction = Download.ShareRatioAction(rawValue: string("ratioAction") ?? "none") ?? .none
            setShareRatioPolicy(for: download.id, limit: ratio, action: ratioAction)
        case "setSequential":
            let enabled = (parameters["enabled"] as? Bool) ?? (string("enabled") != "false")
            setSequentialDownload(enabled, for: download)
        case "setFilePriority":
            if let index = int("index"), let priority = int("priority") {
                setFilePriority(index, priority: priority, for: download)
            }
        case "selectFile":
            if let index = int("index") {
                let selected = (parameters["selected"] as? Bool) ?? (string("selected") != "false")
                setFile(index, selected: selected, for: download)
            }
        default:
            break
        }
    }

    func sendRemoteResponse(status: String, contentType: String, body: String, connection: NWConnection?) {
        sendRemoteResponse(status: status, contentType: contentType, data: Data(body.utf8), connection: connection)
    }

    func sendRemoteResponse(status: String, contentType: String, data: Data, connection: NWConnection?) {
        guard let connection else { return }
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }

}
