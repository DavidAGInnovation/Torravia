//
//  DownloadsViewModel+RemoteControl.swift
//  Torravia
//
//  Authenticated browser control API and diagnostics transport.
//

import Foundation
import Network

@MainActor
extension DownloadsViewModel {
    func handleRemoteRequest(_ request: String, connection: NWConnection?) async {
        let rawSections = request.components(separatedBy: "\r\n\r\n")
        let headerBlock = rawSections.first ?? request
        let body = rawSections.dropFirst().joined(separator: "\r\n\r\n")
        let headerLines = headerBlock.components(separatedBy: "\r\n")
        guard let firstLine = headerLines.first else {
            sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "Malformed request", connection: connection)
            return
        }
        let lineParts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard lineParts.count >= 2 else {
            sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "Malformed request line", connection: connection)
            return
        }
        let method = lineParts[0].uppercased()
        guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method) else {
            sendRemoteResponse(status: "405 Method Not Allowed", contentType: "text/plain", body: "Supported methods: GET, POST, PUT, PATCH, DELETE", connection: connection)
            return
        }
        let path = lineParts[1]
        guard let components = URLComponents(string: "http://localhost\(path)") else {
            sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "Invalid request target", connection: connection)
            return
        }
        let isAPI = components.path == "/api" || components.path.hasPrefix("/api/")
        if method == "GET", !isAPI, alternativeWebUI != nil || alternativeWebUIError != nil {
            if let error = alternativeWebUIError {
                sendRemoteResponse(status: "503 Service Unavailable", contentType: "text/plain", body: error, connection: connection)
            } else if let asset = try? alternativeWebUI?.asset(path: components.path) {
                sendRemoteResponse(status: "200 OK", contentType: asset.contentType, data: asset.data, connection: connection)
            } else {
                sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "Interface asset not found", connection: connection)
            }
            return
        }
        if components.path == "/", method == "GET" {
            sendRemoteResponse(status: "200 OK", contentType: "text/html; charset=utf-8", body: RemoteWebUI.html, connection: connection)
            return
        }
        if components.path == "/web.js", method == "GET" {
            sendRemoteResponse(status: "200 OK", contentType: "application/javascript; charset=utf-8", body: RemoteWebUI.javascript, connection: connection)
            return
        }
        if components.path == "/web-icons.svg", method == "GET" {
            sendRemoteResponse(status: "200 OK", contentType: "image/svg+xml", body: RemoteWebIcons.svg, connection: connection)
            return
        }
        if components.path == "/web.css", method == "GET" {
            sendRemoteResponse(status: "200 OK", contentType: "text/css; charset=utf-8", body: RemoteWebUI.css, connection: connection)
            return
        }
        guard remoteToken(from: components, headerLines: headerLines) == remoteControlToken else {
            sendRemoteResponse(status: "401 Unauthorized", contentType: "text/plain", body: "Invalid token", connection: connection)
            return
        }
        let route: String = {
            // Keep the native API names while also accepting the familiar
            // torrent-oriented aliases used by automation clients.
            switch components.path {
            case "/api/torrents", "/api/torrents/info": return "/api/downloads"
            case "/api/torrents/properties": return "/api/downloads/properties"
            case "/api/torrents/files": return "/api/files"
            case "/api/torrents/peers": return "/api/peers"
            case "/api/torrents/trackers": return "/api/trackers"
            case "/api/torrents/pieces": return "/api/pieces"
            case "/api/torrents/diagnostics": return "/api/diagnostics"
            default: return components.path
            }
        }()
        let query = Dictionary( (components.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        }, uniquingKeysWith: { _, last in last })
        let jsonBody = body.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]

        if route == "/api" || route == "/api/capabilities" {
            let payload: [String: Any] = [
                "name": "Torravia Control API",
                "version": 3,
                    "transport": "\(remoteAllowsLAN ? "LAN" : "loopback") \(remoteControlURL?.scheme == "https" ? "HTTPS" : "HTTP") with token authentication",
                    "methods": ["GET", "POST", "PUT", "PATCH", "DELETE"],
                "features": ["headless", "alternative-browser-ui", "https", "queue", "queue-snapshots", "file-priorities", "file-selection", "rss-rules", "rss-episodes", "rss-multi-feed-rules", "rss-rule-preview", "rss-http-cache", "categories", "tags", "peer-inspection", "discovery", "tracker-management", "web-seeds", "manual-peer-connections", "bandwidth-limits", "incremental-sync", "event-polling", "unified-diagnostics", "torrent-api-aliases", "batch-diagnostics", "bandwidth-schedule", "browser-ui", "torrent-file-upload", "seeding-time-limits", "inactivity-limits"],
                "routes": [
                    "GET /api/app",
                    "GET /api/transfer",
                    "GET /api/log",
                    "POST /api/search {query,mode?,maxResults?}",
                    "GET /api/downloads",
                    "GET /api/downloads/properties?id=<torrent-id>",
                    "GET /api/diagnostics?id=<torrent-id>&refresh=true",
                    "GET /api/trackers?id=<torrent-id>",
                    "GET /api/downloads?rid=<revision> (incremental sync)",
                    "GET /api/events?rid=<revision> (incremental event sync)",
                    "GET|POST|PUT|DELETE /api/categories",
                    "GET|POST|PUT|DELETE /api/tags",
                    "GET /api/sync?rid=<revision>",
                    "POST /api/downloads {magnet,title?,category?}",
                    "POST /api/queue {action,id?,priority?}",
                    "GET|PUT /api/preferences",
                    "GET|POST|PUT|DELETE /api/rss",
                    "POST /api/rss {action:refresh|reset-history|move-up|move-down}",
                    "POST /api/rss/preview",
                    "PUT|PATCH /api/downloads?id=<torrent-id>",
                    "GET|PUT /api/files?id=<torrent-id>",
                    "PUT /api/files?id=<torrent-id> {action:selectAll|skipAll|priorityAll}",
                    "POST /api/peers {action:add|ban,address,id}",
                    "GET|POST|DELETE /api/discovery {action,reannounce,tracker,web-seed}",
                    "GET /api/pieces?id=<torrent-id>",
                    "GET /api/inspection?id=<torrent-id>",
                    "GET /api/peers?id=<torrent-id>",
                    "GET /api/discovery?id=<torrent-id>"
                ]
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            sendRemoteResponse(status: "200 OK", contentType: "application/json", body: String(data: json, encoding: .utf8) ?? "{}", connection: connection)
            return
        }

        if route == "/api/preferences", method == "PUT" || method == "PATCH" {
            guard let jsonBody else {
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "Expected a JSON object", connection: connection)
                return
            }
            applyRemotePreferences(jsonBody)
            sendRemoteJSON(["ok": true, "preferences": remotePreferencesPayload() ], connection: connection)
            return
        }

        if route == "/api/app", method == "GET" {
            sendRemoteJSON([
                "name": "Torravia",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                "apiVersion": 3,
                "engine": networkStatus?.engineVersion ?? "libtorrent",
                "platform": "macOS",
                "headless": isHeadless,
                "alternativeBrowserUI": alternativeWebUI != nil
            ], connection: connection)
            return
        }

        if route == "/api/transfer", method == "GET" {
            let downloaded = downloads.reduce(Int64(0)) { $0 + $1.downloadedBytes }
            let uploaded = downloads.reduce(Int64(0)) { $0 + $1.uploadedBytes }
            let downloadRate = downloads.reduce(Int64(0)) { $0 + $1.speedBytesPerSec }
            let uploadRate = downloads.reduce(Int64(0)) { $0 + $1.uploadSpeedBytesPerSec }
            let active = downloads.filter { $0.status == .downloading }.count
            sendRemoteJSON([
                "downloadedBytes": downloaded,
                "uploadedBytes": uploaded,
                "downloadSpeed": downloadRate,
                "uploadSpeed": uploadRate,
                "activeTorrents": active,
                "totalTorrents": downloads.count,
                "listenPort": networkStatus?.listenPort ?? 0,
                "isListening": networkStatus?.isListening ?? false,
                "dhtNodes": networkStatus?.dhtNodes ?? 0,
                "trackerReplies": networkStatus?.trackerReplies ?? 0
            ], connection: connection)
            return
        }

        if route == "/api/log", method == "GET" {
            let failedDownloads = downloads.compactMap { download -> [String: Any]? in
                guard let message = download.errorMessage, !message.isEmpty else { return nil }
                return ["id": download.id.uuidString, "title": download.title, "message": message]
            }
            let warnings = failedDownloads + (networkStatus?.lastTrackerError.map {
                [["source": "tracker", "message": $0]] as [[String: Any]]
            } ?? [])
            sendRemoteJSON([
                "warnings": warnings,
                "network": [
                    "listenState": networkStatus?.listenState ?? "unknown",
                    "listenPort": networkStatus?.listenPort ?? 0,
                    "dhtStatus": networkStatus?.dhtStatus ?? "unknown",
                    "dhtNodes": networkStatus?.dhtNodes ?? 0,
                    "trackerStatus": networkStatus?.trackerStatus ?? "unknown",
                    "trackerReplies": networkStatus?.trackerReplies ?? 0,
                    "trackerErrors": networkStatus?.trackerErrors ?? 0,
                    "alertsDropped": networkStatus?.alertsDropped ?? 0
                ]
            ], connection: connection)
            return
        }

        if route == "/api/search", method == "POST" {
            guard let rawQuery = jsonBody?["query"] as? String else {
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "query is required", connection: connection)
                return
            }
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "query cannot be empty", connection: connection)
                return
            }
            let mode: SearchMode = (jsonBody?["mode"] as? String)?.lowercased() == "balanced" ? .balanced : .fast
            let requestedMax = (jsonBody?["maxResults"] as? NSNumber)?.intValue
            let maxResults = min(max(requestedMax ?? mode.tuning.maxResults, 1), 200)
            do {
                let provider = SearchProvider(mode: mode, maxResults: maxResults, enabledSites: SearchPreferencesStore.shared.enabledSites)
                let results = try await provider.search(query: query)
                let encoded = try JSONEncoder().encode(results)
                let jsonResults = try JSONSerialization.jsonObject(with: encoded)
                sendRemoteJSON(["query": query, "results": jsonResults], connection: connection)
            } catch {
                sendRemoteJSON(["query": query, "results": [], "error": error.localizedDescription], status: "502 Bad Gateway", connection: connection)
            }
            return
        }

        if route == "/api/rss", method == "POST",
           (jsonBody?["action"] as? String)?.lowercased() == "refresh" {
            refreshRSSFeeds()
            sendRemoteJSON(["ok": true, "action": "refresh"], status: "202 Accepted", connection: connection)
            return
        }

        if route == "/api/rss/preview", method == "POST", let jsonBody {
            do {
                let existing = (jsonBody["id"] as? String).flatMap(UUID.init(uuidString:))
                    .flatMap { id in automation.rssRules.first { $0.id == id } }
                let rule = try remoteRSSRule(jsonBody, existing: existing)
                let title = jsonBody["title"] as? String ?? ""
                let reason = title.isEmpty ? "Enter a sample release title." : rule.matchReason(title: title)
                sendRemoteJSON(["matches": reason == nil, "reason": reason ?? "Matches this rule.",
                                "episodes": RSSEpisodeFilter.keys(in: title)], connection: connection)
            } catch {
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: error.localizedDescription, connection: connection)
            }
            return
        }

        if route == "/api/rss", method == "POST", let action = jsonBody?["action"] as? String {
            guard let id = ((jsonBody?["id"] as? String) ?? query["id"]).flatMap(UUID.init(uuidString:)),
                  automation.rssRules.contains(where: { $0.id == id }) else {
                sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "RSS rule not found", connection: connection)
                return
            }
            switch action {
            case "reset-history": automation.resetRSSHistory(id: id)
            case "move-up": automation.moveRSSRule(id: id, offset: -1)
            case "move-down": automation.moveRSSRule(id: id, offset: 1)
            default:
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "Unknown RSS action", connection: connection)
                return
            }
            sendRemoteJSON(["ok": true, "rss": remoteRSSPayload()], connection: connection)
            return
        }

        if route == "/api/rss", method == "POST" || method == "PUT" || method == "PATCH" {
            guard let jsonBody else {
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "RSS rule JSON is required", connection: connection)
                return
            }
            var existing: DownloadAutomationStore.RSSRule?
            if method != "POST" {
                guard let id = ((jsonBody["id"] as? String) ?? query["id"]).flatMap(UUID.init(uuidString:)),
                      let rule = automation.rssRules.first(where: { $0.id == id }) else {
                    sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "RSS rule not found", connection: connection)
                    return
                }
                existing = rule
            }
            do {
                let rule = try remoteRSSRule(jsonBody, existing: existing)
                if existing == nil { automation.insertRSSRule(rule) } else { automation.updateRSSRule(rule) }
                sendRemoteJSON(["ok": true, "rss": remoteRSSPayload()], connection: connection)
            } catch {
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: error.localizedDescription, connection: connection)
            }
            return
        }

        if route == "/api/rss", method == "DELETE" {
            guard let idString = query["id"], let id = UUID(uuidString: idString),
                  automation.rssRules.contains(where: { $0.id == id }) else {
                sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "RSS rule not found", connection: connection)
                return
            }
            automation.removeRSSRule(id: id)
            sendRemoteJSON(["ok": true], connection: connection)
            return
        }

        if route == "/api/queue", method == "GET" {
            sendRemoteJSON([
                "revision": remoteRevision,
                "queue": remoteDownloadsPayload(),
                "limits": [
                    "queueingEnabled": preferences.isQueueingEnabled,
                    "maximumActiveDownloads": preferences.maximumActiveDownloads,
                    "maximumActiveSeeds": preferences.maximumActiveSeeds,
                    "maximumActiveTorrents": preferences.maximumActiveTorrents,
                    "ignoreSlowTorrents": preferences.ignoreSlowTorrents
                ]
            ], connection: connection)
            return
        }

        if route == "/api/downloads/properties", method == "GET" {
            guard let id = query["id"].flatMap(UUID.init),
                  let download = downloads.first(where: { $0.id == id }) else {
                sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "Download not found", connection: connection)
                return
            }
            sendRemoteJSON(remoteDownloadProperties(download), connection: connection)
            return
        }

        if route == "/api/diagnostics", method == "GET" {
            if let id = query["id"].flatMap(UUID.init),
               let download = downloads.first(where: { $0.id == id }) {
                let refresh = query["refresh"]?.lowercased() != "false"
                if refresh {
                    setPeerInspectionEnabled(true, for: id)
                    refreshDiscovery(for: id)
                    requestPieceAvailability(for: id)
                    requestPieceInspection(for: id)
                }
                sendRemoteJSON(remoteDiagnosticsPayload(for: download), connection: connection)
                return
            }

            // A batch view makes it possible for a remote monitor to discover
            // the slowest torrent and its bottleneck with one authenticated call.
            let diagnostics = downloads.map(remoteDiagnosticsPayload(for:))
            sendRemoteJSON([
                "network": [
                    "listenPort": networkStatus?.listenPort ?? 0,
                    "isListening": networkStatus?.isListening ?? false,
                    "listenState": networkStatus?.listenState ?? "unknown",
                    "dhtStatus": networkStatus?.dhtStatus ?? "unknown",
                    "dhtNodes": networkStatus?.dhtNodes ?? 0,
                    "trackerReplies": networkStatus?.trackerReplies ?? 0,
                    "trackerErrors": networkStatus?.trackerErrors ?? 0,
                    "alertsDropped": networkStatus?.alertsDropped ?? 0
                ],
                "torrents": diagnostics
            ], connection: connection)
            return
        }

        if route == "/api/trackers", method == "GET" {
            guard let id = query["id"].flatMap(UUID.init),
                  downloads.contains(where: { $0.id == id }) else {
                sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "Download not found", connection: connection)
                return
            }
            if query["refresh"]?.lowercased() != "false" {
                refreshDiscovery(for: id)
            }
            sendRemoteJSON(remoteDiscoveryPayload(for: id), connection: connection)
            return
        }

        if route == "/api/torrent-file", method == "POST" {
            guard let encoded = jsonBody?["data"] as? String, let data = Data(base64Encoded: encoded),
                  data.count <= 4 * 1024 * 1024 else {
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "A base64-encoded .torrent file up to 4 MiB is required", connection: connection)
                return
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let url = folder.appendingPathComponent("upload.torrent")
                try data.write(to: url)
                let result = await addTorrentFile(at: url, category: jsonBody?["category"] as? String ?? "")
                switch result {
                case .added: sendRemoteJSON(["ok": true], status: "201 Created", connection: connection)
                case .duplicate(let title): sendRemoteJSON(["error": "Torrent already exists: \(title ?? "Untitled")"], status: "409 Conflict", connection: connection)
                case .failed(let message): sendRemoteJSON(["error": message], status: "400 Bad Request", connection: connection)
                }
            } catch { sendRemoteJSON(["error": error.localizedDescription], status: "400 Bad Request", connection: connection) }
            return
        }

        if route == "/api/downloads", method == "POST" {
            guard let jsonBody, let magnet = jsonBody["magnet"] as? String,
                  Self.isValidMagnetLink(magnet) else {
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "A valid magnet link is required", connection: connection)
                return
            }
            let id = addMagnetLink(magnet,
                                   title: jsonBody["title"] as? String,
                                   category: jsonBody["category"] as? String ?? "")
            if let id, let download = downloads.first(where: { $0.id == id }) {
                applyRemoteDownloadOptions(jsonBody, to: download)
                let updated = downloads.first(where: { $0.id == id }) ?? download
                sendRemoteJSON(["ok": true, "download": remoteDownloadProperties(updated)], connection: connection)
            } else {
                sendRemoteJSON(["ok": false, "downloads": remoteDownloadsPayload()], status: "409 Conflict", connection: connection)
            }
            return
        }

        if route == "/api/downloads", method == "PUT" || method == "PATCH" {
            let body = jsonBody ?? [:]
            guard let idString = (body["id"] as? String) ?? query["id"],
                  let id = UUID(uuidString: idString),
                  let download = downloads.first(where: { $0.id == id }) else {
                sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "Download not found", connection: connection)
                return
            }
            for key in ["seedingTimeLimitMinutes", "inactiveSeedingTimeLimitMinutes"] where body.keys.contains(key) {
                if body[key] is NSNull { continue }
                guard let value = body[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= 5_256_000,
                      value.doubleValue.rounded() == value.doubleValue else {
                    sendRemoteJSON(["error": "Seeding limits must be whole minutes from 0 to 5256000; 0 disables the limit."], status: "400 Bad Request", connection: connection)
                    return
                }
            }
            applyRemoteDownloadOptions(body, to: download)
            let updated = downloads.first(where: { $0.id == id }) ?? download
            sendRemoteJSON(["ok": true, "download": remoteDownloadProperties(updated)], connection: connection)
            return
        }

        if route == "/api/queue", method == "POST" {
            let action = jsonBody?["action"] as? String ?? query["action"] ?? ""
            let selectedID = (jsonBody?["id"] as? String).flatMap(UUID.init) ?? query["id"].flatMap(UUID.init)
            let selected = selectedID.flatMap { id in downloads.first(where: { $0.id == id }) }
            switch action {
            case "pauseAll":
                downloads.filter { $0.isPending && $0.status != .paused }.forEach { pause($0) }
            case "resumeAll":
                downloads.filter { $0.status == .paused || $0.status == .failed }.forEach { resume($0) }
            case "forceStartAll":
                downloads.filter { $0.isPending }.forEach { forceStart($0) }
            case "moveTop":
                if let selected { moveToTop(selected) }
            case "moveBottom":
                if let selected { moveToBottom(selected) }
            case "moveUp":
                if let selected { moveUp(selected) }
            case "moveDown":
                if let selected { moveDown(selected) }
            case "setPriority":
                guard let selected else { break }
                let priority = (jsonBody?["priority"] as? Int) ?? Int(query["priority"] ?? "0") ?? 0
                setQueuePriority(priority, for: selected)
            default:
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "Unknown queue action", connection: connection)
                return
            }
            sendRemoteJSON(["ok": true, "action": action, "downloads": remoteDownloadsPayload()], connection: connection)
            return
        }

        if route == "/api/files", (method == "PUT" || method == "PATCH") {
            guard let idString = query["id"], let id = UUID(uuidString: idString),
                  let download = downloads.first(where: { $0.id == id }) else {
                sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "Download not found", connection: connection)
                return
            }
            let action = (jsonBody?["action"] as? String) ?? query["action"]
            if let action {
                switch action {
                case "selectAll": setAllFilesSelected(true, for: download)
                case "skipAll": setAllFilesSelected(false, for: download)
                case "priorityAll":
                    let priority = (jsonBody?["priority"] as? Int) ?? Int(query["priority"] ?? "4") ?? 4
                    setAllFilePriorities(priority, for: download)
                default:
                    sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "Unknown file action", connection: connection)
                    return
                }
                sendRemoteJSON(["ok": true, "action": action], connection: connection)
                return
            }
            guard let jsonBody,
                  let index = (jsonBody["index"] as? Int) ?? Int(query["index"] ?? "") else {
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "id and index are required", connection: connection)
                return
            }
            if let selected = jsonBody["selected"] as? Bool {
                setFile(index, selected: selected, for: download)
            }
            if let priority = jsonBody["priority"] as? Int {
                setFilePriority(index, priority: priority, for: download)
            }
            if let name = jsonBody["name"] as? String {
                renameFile(index, to: name, for: download)
            }
            sendRemoteJSON(["ok": true], connection: connection)
            return
        }

        if route == "/api/action", method != "GET" {
            guard let jsonBody,
                  let idString = (jsonBody["id"] as? String) ?? query["id"],
                  let id = UUID(uuidString: idString),
                  let download = downloads.first(where: { $0.id == id }),
                  let action = (jsonBody["action"] as? String) ?? query["action"] else {
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "id and action are required", connection: connection)
                return
            }
            var parameters = query.mapValues { $0 as Any }
            for (key, value) in jsonBody { parameters[key] = value }
            performRemoteAction(action, for: download, parameters: parameters)
            sendRemoteJSON(["ok": true], connection: connection)
            return
        }
        if route == "/api/preferences" {
            sendRemoteJSON(remotePreferencesPayload(), connection: connection)
            return
        }
        if route == "/api/rss" {
            sendRemoteJSON(remoteRSSPayload(), connection: connection)
            return
        }
        if route == "/api/categories" {
            if method == "GET" {
                sendRemoteJSON(remoteCategoriesPayload(), connection: connection)
                return
            }
            if method == "POST" {
                guard let rawName = jsonBody?["name"] as? String else {
                    sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "name is required", connection: connection)
                    return
                }
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "name cannot be empty", connection: connection)
                    return
                }
                managedCategoryPaths[name] = (jsonBody?["savePath"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                persistManagedCatalogs()
                sendRemoteJSON(["ok": true, "category": ["name": name, "savePath": managedCategoryPaths[name] ?? ""]], connection: connection)
                return
            }
            if method == "PUT" || method == "PATCH" {
                let oldName = (jsonBody?["oldName"] as? String) ?? query["oldName"] ?? ""
                let newName = (jsonBody?["name"] as? String) ?? query["name"] ?? ""
                guard !oldName.isEmpty, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "oldName and name are required", connection: connection)
                    return
                }
                let normalized = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                let path = managedCategoryPaths.removeValue(forKey: oldName) ?? ""
                managedCategoryPaths[normalized] = (jsonBody?["savePath"] as? String) ?? path
                for download in downloads where download.category == oldName {
                    update(downloadID: download.id) { $0.category = normalized }
                }
                persistManagedCatalogs()
                sendRemoteJSON(["ok": true, "categories": remoteCategoriesPayload()], connection: connection)
                return
            }
            if method == "DELETE" {
                let name = query["name"] ?? (jsonBody?["name"] as? String) ?? ""
                managedCategoryPaths.removeValue(forKey: name)
                for download in downloads where download.category == name {
                    update(downloadID: download.id) { $0.category = "" }
                }
                persistManagedCatalogs()
                sendRemoteJSON(["ok": true], connection: connection)
                return
            }
        }
        if route == "/api/tags" {
            if method == "GET" {
                sendRemoteJSON(remoteTagsPayload(), connection: connection)
                return
            }
            if method == "POST" {
                let values = (jsonBody?["name"] as? String ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !values.isEmpty else {
                    sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "name is required", connection: connection)
                    return
                }
                managedTags.formUnion(values)
                persistManagedCatalogs()
                sendRemoteJSON(["ok": true, "tags": remoteTagsPayload()], connection: connection)
                return
            }
            if method == "PUT" || method == "PATCH" {
                let oldName = (jsonBody?["oldName"] as? String) ?? query["oldName"] ?? ""
                let newName = ((jsonBody?["name"] as? String) ?? query["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !oldName.isEmpty, !newName.isEmpty else {
                    sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "oldName and name are required", connection: connection)
                    return
                }
                managedTags.remove(oldName)
                managedTags.insert(newName)
                for download in downloads where download.tags.contains(oldName) {
                    updateMetadata(for: download.id,
                                   category: download.category,
                                   tags: download.tags.map { $0 == oldName ? newName : $0 })
                }
                for rule in automation.rssRules where rule.tags.contains(oldName) {
                    var updated = rule
                    updated.tags = rule.tags.map { $0 == oldName ? newName : $0 }
                    automation.updateRSSRule(updated)
                }
                persistManagedCatalogs()
                sendRemoteJSON(["ok": true, "tags": remoteTagsPayload()], connection: connection)
                return
            }
            if method == "DELETE" {
                let name = query["name"] ?? (jsonBody?["name"] as? String) ?? ""
                managedTags.remove(name)
                for download in downloads where download.tags.contains(name) {
                    updateMetadata(for: download.id,
                                   category: download.category,
                                   tags: download.tags.filter { $0 != name })
                }
                for rule in automation.rssRules where rule.tags.contains(name) {
                    var updated = rule
                    updated.tags.removeAll { $0 == name }
                    automation.updateRSSRule(updated)
                }
                persistManagedCatalogs()
                sendRemoteJSON(["ok": true], connection: connection)
                return
            }
        }
        if (route == "/api/downloads" || route == "/api/sync"), method == "GET", let ridString = query["rid"],
           let rid = Int(ridString) {
            let changed = rid != remoteRevision
            let changedIDs = Set(remoteTorrentRevisions.compactMap { key, revision in
                revision > rid ? key : nil
            })
            let changedTorrents = remoteDownloadsPayload().filter {
                guard let id = $0["id"] as? String else { return false }
                return changedIDs.contains(id)
            }
            let removedTorrents = remoteRemovedTorrentRevisions.compactMap { key, revision in
                revision > rid ? key : nil
            }.sorted()
            let payload: [String: Any] = [
                "rid": remoteRevision,
                "full_update": false,
                "torrents": changed ? changedTorrents : [],
                "torrents_removed": changed ? removedTorrents : [],
                "categories": remoteCategoriesPayload(),
                "tags": remoteTagsPayload()
            ]
            sendRemoteJSON(payload, connection: connection)
            return
        }
        if route == "/api/events", method == "GET" {
            let rid = Int(query["rid"] ?? "-1") ?? -1
            let changed = rid != remoteRevision
            let changedIDs = Set(remoteTorrentRevisions.compactMap { key, revision in
                revision > rid ? key : nil
            })
            let changedTorrents = remoteDownloadsPayload().filter {
                guard let id = $0["id"] as? String else { return false }
                return changedIDs.contains(id)
            }
            let removedTorrents = remoteRemovedTorrentRevisions.compactMap { key, revision in
                revision > rid ? key : nil
            }.sorted()
            sendRemoteJSON([
                "rid": remoteRevision,
                "changed": changed,
                "torrents": changed ? changedTorrents : [],
                "torrentsRemoved": changed ? removedTorrents : [],
                "queue": remoteDownloadsPayload(),
                "preferences": remotePreferencesPayload()
            ], connection: connection)
            return
        }
        if route == "/api/downloads" {
            sendRemoteJSON(remoteDownloadsPayload(), connection: connection)
            return
        }
        if route == "/api/files", method == "GET" {
            guard let id = query["id"].flatMap(UUID.init),
                  let download = downloads.first(where: { $0.id == id }) else {
                sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "Download not found", connection: connection)
                return
            }
            let files = download.files.enumerated().map { index, file in
                var payload: [String: Any] = ["index": index,
                 "name": file.relativePath,
                 "length": file.length,
                 "selected": download.selectedFileIndices?.contains(index) ?? true,
                 "priority": download.filePriorities?.indices.contains(index) == true
                    ? download.filePriorities![index] : 4]
                if let detail = pieceInspections[id]?.files.first(where: { $0.index == index }) {
                    payload["progress"] = detail.progress
                    payload["availability"] = detail.availability
                    payload["pieceStart"] = detail.pieceStart
                    payload["pieceEnd"] = detail.pieceEnd
                }
                return payload
            }
            let json = (try? JSONSerialization.data(withJSONObject: files)) ?? Data("[]".utf8)
            sendRemoteResponse(status: "200 OK", contentType: "application/json", body: String(data: json, encoding: .utf8) ?? "[]", connection: connection)
            return
        }
        if route == "/api/pieces", let idString = query["id"], let id = UUID(uuidString: idString) {
            guard downloads.contains(where: { $0.id == id }) else {
                sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "Download not found", connection: connection)
                return
            }
            requestPieceAvailability(for: id)
            let pieces = pieceAvailabilitySnapshots[id] ?? []
            sendRemoteJSON([
                "id": id.uuidString,
                "pieces": pieces,
                "availablePieces": pieces.filter { $0 > 0 }.count,
                "pieceCount": pieces.count
            ], connection: connection)
            return
        }
        if route == "/api/inspection", let idString = query["id"], let id = UUID(uuidString: idString) {
            guard downloads.contains(where: { $0.id == id }) else {
                sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "Download not found", connection: connection)
                return
            }
            requestPieceInspection(for: id)
            sendRemoteJSON(remoteInspectionPayload(for: id), connection: connection)
            return
        }
        if route == "/api/peers", method == "POST" {
            guard let jsonBody,
                  let idString = (jsonBody["id"] as? String) ?? query["id"],
                  let id = UUID(uuidString: idString),
                  let action = (jsonBody["action"] as? String) ?? query["action"],
                  let address = (jsonBody["address"] as? String) ?? query["address"],
                  !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "id, action and address are required", connection: connection)
                return
            }
            switch action {
            case "add": addPeer(address, for: id)
            case "ban": banPeerAddress(address, for: id)
            default:
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "action must be add or ban", connection: connection)
                return
            }
            sendRemoteJSON(["ok": true, "action": action], connection: connection)
            return
        }
        if route == "/api/peers", let idString = query["id"], let id = UUID(uuidString: idString) {
            guard downloads.contains(where: { $0.id == id }) else {
                sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "Download not found", connection: connection)
                return
            }
            if query["refresh"]?.lowercased() != "false" {
                setPeerInspectionEnabled(true, for: id)
            }
            sendRemoteJSON(remotePeersPayload(for: id), connection: connection)
            return
        }
        if route == "/api/discovery", method == "POST" || method == "DELETE" {
            let body = jsonBody ?? [:]
            guard let idString = (body["id"] as? String) ?? query["id"],
                  let id = UUID(uuidString: idString) else {
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "id is required", connection: connection)
                return
            }
            let action = (body["action"] as? String) ?? query["action"] ?? (method == "DELETE" ? "removeTracker" : "")
            let url = (body["url"] as? String) ?? query["url"] ?? ""
            let tier: Int = {
                if let value = body["tier"] as? Int { return value }
                if let value = body["tier"] as? NSNumber { return value.intValue }
                return Int(query["tier"] ?? "") ?? 0
            }()
            switch action {
            case "reannounce": reannounce(for: id)
            case "addTracker": addTracker(url, tier: tier, for: id)
            case "removeTracker": removeTracker(url, for: id)
            case "addWebSeed": addWebSeed(url, for: id)
            case "removeWebSeed": removeWebSeed(url, for: id)
            default:
                sendRemoteResponse(status: "400 Bad Request", contentType: "text/plain", body: "Unknown discovery action", connection: connection)
                return
            }
            sendRemoteJSON(["ok": true, "action": action], connection: connection)
            return
        }
        if route == "/api/discovery", let idString = query["id"], let id = UUID(uuidString: idString) {
            guard downloads.contains(where: { $0.id == id }) else {
                sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "Download not found", connection: connection)
                return
            }
            if query["refresh"]?.lowercased() != "false" {
                refreshDiscovery(for: id)
            }
            sendRemoteJSON(remoteDiscoveryPayload(for: id), connection: connection)
            return
        }
        if route == "/api/action", let idString = query["id"], let id = UUID(uuidString: idString),
           let download = downloads.first(where: { $0.id == id }), let action = query["action"] {
            performRemoteAction(action, for: download, parameters: query.mapValues { $0 as Any })
            sendRemoteJSON(["ok": true], connection: connection)
            return
        }
        sendRemoteResponse(status: "404 Not Found", contentType: "text/plain", body: "Unknown endpoint", connection: connection)
    }
}
