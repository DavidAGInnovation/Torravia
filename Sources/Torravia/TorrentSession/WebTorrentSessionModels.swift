//
//  WebTorrentSessionModels.swift
//  Torravia
//
//  Session configuration and typed event payloads.
//

import Foundation

extension WebTorrentSession {
    struct NetworkConfiguration: Equatable, Sendable {
        let listenPort: Int
        let globalConnectionLimit: Int
        let perTorrentConnectionLimit: Int
        let downloadLimitBytesPerSecond: Int
        let uploadLimitBytesPerSecond: Int
        let globalUploadSlots: Int
        let perTorrentUploadSlots: Int
        let queueingEnabled: Bool
        let maximumActiveDownloads: Int
        let maximumActiveSeeds: Int
        let maximumActiveTorrents: Int
        let ignoreSlowTorrents: Bool
        let networkInterface: String
        let transportMode: String
        let encryptionMode: String
        let diskIOBackend: String
        let diskIOReadMode: Int
        let diskIOWriteMode: Int
        let preallocateFiles: Bool
        let outgoingPortStart: Int
        let outgoingPortEnd: Int
        let additionalTrackerURLs: [String]
        /// Refreshed trackers_best candidates used only by the adaptive
        /// fallback for slow, low-peer downloads.
        let adaptiveTrackerURLs: [String]
        let dhtEnabled: Bool
        let peerExchangeEnabled: Bool
        let localPeerDiscoveryEnabled: Bool
        let upnpEnabled: Bool
        let natpmpEnabled: Bool
        let proxyType: String
        let proxyHost: String
        let proxyPort: Int
        let proxyUsername: String
        let proxyPassword: String
        let proxyPeerConnections: Bool
        let proxyHostnames: Bool
        let proxyTrackerConnections: Bool
        let anonymousMode: Bool
        let ssrfMitigationEnabled: Bool
        let validateHTTPSTrackers: Bool
        let blockPrivilegedPeerPorts: Bool
        let allowMultipleConnectionsPerIP: Bool
        let i2pEnabled: Bool
        let i2pHost: String
        let i2pPort: Int
        let i2pMixedMode: Bool
        let blockedIPRanges: [String]
    }

    enum Event: Equatable {
        struct File: Equatable, Hashable {
            let name: String
            let length: Int64
            var isPadding = false
        }

        struct Added: Equatable {
            let id: String
            let name: String
            let infoHash: String
            let path: URL
            let length: Int64
            let files: [File]
            let connectablePeers: Int
            let connectedSeeders: Int
            let connectedLeechers: Int
            let knownPeers: Int
            let knownSeeders: Int
            let knownLeechers: Int
            let swarmSeeders: Int?
            let swarmLeechers: Int?
            let metainfo: Data?
        }

        struct Progress: Equatable {
            let id: String
            let progress: Double
            let downloadSpeed: Double
            let uploadSpeed: Double
            let downloaded: Int64
            let uploaded: Int64
            let isQueued: Bool
            let numPeers: Int
            let connectablePeers: Int
            let connectedSeeders: Int
            let connectedLeechers: Int
            let knownPeers: Int
            let knownSeeders: Int
            let knownLeechers: Int
            let diskBacklogBytes: Int64
            let diskQueueLimitBytes: Int64
            let diskQueueWarnings: Int
            let schedulerRank: Int
            let swarmSeeders: Int?
            let swarmLeechers: Int?
            let timeRemaining: TimeInterval?
            let path: URL
            var isProgressReady: Bool = true
            var isFinished: Bool = false
            var seedingTimeSeconds: Int64 = 0
            var inactiveSeedingTimeSeconds: Int64 = 0
        }

        struct Completed: Equatable {
            let id: String
            let path: URL
            let files: [File]
        }

        struct NetworkStatus: Equatable {
            let listenPort: Int
            let isListening: Bool
            let listenState: String
            let connectionLimit: Int
            let engineVersion: String
            let upnpStatus: String
            let natpmpStatus: String
            let trackerStatus: String
            let trackerAnnounces: Int
            let trackerReplies: Int
            let trackerErrors: Int
            let alertsDropped: Int
            let lastTrackerURL: String?
            let lastTrackerError: String?
            let dhtStatus: String
            let dhtReplies: Int
            let dhtNodes: Int
        }

        struct Peer: Equatable, Identifiable {
            var id: String { "\(address):\(port)" }
            let address: String
            let port: Int
            let client: String
            let transport: String
            let direction: String
            let sources: [String]
            let downloadSpeed: Int64
            let uploadSpeed: Int64
            let progress: Double
            let isSeed: Bool
        }

        struct PeerSnapshot: Equatable {
            let id: String
            let availability: Double
            let peers: [Peer]
        }

        struct DiscoverySnapshot: Equatable {
            struct Tracker: Equatable, Identifiable {
                var id: String { "\(tier):\(url)" }
                let url: String
                let tier: Int
                let state: String
                let source: Int
                let fails: Int
                let updating: Bool
                let message: String
                let scrapeComplete: Int?
                let scrapeIncomplete: Int?
            }

            let id: String
            let trackers: [Tracker]
            let webSeeds: [String]
            let trackerPeers: Int?
        }

        struct PieceAvailability: Equatable {
            let id: String
            let pieces: [Int]
        }

        struct PieceInspection: Equatable {
            struct File: Equatable {
                let index: Int
                let name: String
                let length: Int64
                let progress: Double
                let availability: Double
                let priority: Int
                let pieceStart: Int
                let pieceEnd: Int
            }

            struct Piece: Equatable {
                let index: Int
                let have: Bool
                let availability: Int
                let priority: Int
                let hash: String
            }

            let id: String
            let pieceLength: Int
            let files: [File]
            let pieces: [Piece]
        }

        case ready
        case added(Added)
        case progress(Progress)
        case done(Completed)
        case networkStatus(NetworkStatus)
        case peers(PeerSnapshot)
        case discovery(DiscoverySnapshot)
        case pieceAvailability(PieceAvailability)
        case pieceInspection(PieceInspection)
        case paused(id: String)
        case resumed(id: String)
        case cancelled(id: String)
        case seedingStopped(id: String)
        case shareRatioReached(id: String, action: String)
        case seedingLimitReached(id: String, action: String, reason: String)
        case resumeRejected(id: String, message: String)
        case resumeRechecking(id: String, message: String)
        case warning(id: String?, message: String)
        case storageError(id: String, message: String)
        case noPeers(id: String, announceType: String?)
        case error(id: String?, message: String)
        case stopped(code: Int32)
    }
}
