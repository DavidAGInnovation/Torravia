import Foundation
import Combine
import Security

enum TorrentTransportMode: String, CaseIterable, Identifiable {
    case both, tcp, utp
    var id: String { rawValue }
    var title: String { self == .both ? "TCP and µTP" : rawValue.uppercased() }
}

enum TorrentEncryptionMode: String, CaseIterable, Identifiable {
    case enabled, required, disabled
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum TorrentDiskIOBackend: String, CaseIterable, Identifiable {
    case automatic, mmap, posix, pread

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .mmap: return "Memory mapped"
        case .posix: return "POSIX"
        case .pread: return "pread/pwrite"
        }
    }
}

enum TorrentProxyType: String, CaseIterable, Identifiable {
    case none, socks4, socks5, http
    var id: String { rawValue }
    var title: String { self == .none ? "None" : rawValue.uppercased() }
}

final class SeedingPreferencesStore: ObservableObject {
    static let shared = SeedingPreferencesStore()

    @Published var isSeedingEnabled: Bool {
        didSet { persistSeeding() }
    }

    @Published var areNotificationsEnabled: Bool {
        didSet { persistNotifications() }
    }

    @Published var isCompletionSoundEnabled: Bool {
        didSet { defaults.set(isCompletionSoundEnabled, forKey: Keys.completionSoundEnabled) }
    }

    @Published var listenPort: Int {
        didSet { defaults.set(listenPort, forKey: Keys.listenPort) }
    }

    @Published var globalConnectionLimit: Int {
        didSet { defaults.set(globalConnectionLimit, forKey: Keys.globalConnectionLimit) }
    }

    @Published var perTorrentConnectionLimit: Int {
        didSet { defaults.set(perTorrentConnectionLimit, forKey: Keys.perTorrentConnectionLimit) }
    }

    @Published var downloadLimitMBps: Int {
        didSet { defaults.set(downloadLimitMBps, forKey: Keys.downloadLimitMBps) }
    }

    @Published var uploadLimitMBps: Int {
        didSet { defaults.set(uploadLimitMBps, forKey: Keys.uploadLimitMBps) }
    }

    @Published var globalUploadSlots: Int {
        didSet { defaults.set(globalUploadSlots, forKey: Keys.globalUploadSlots) }
    }

    @Published var perTorrentUploadSlots: Int {
        didSet { defaults.set(perTorrentUploadSlots, forKey: Keys.perTorrentUploadSlots) }
    }

    @Published var isQueueingEnabled: Bool {
        didSet { defaults.set(isQueueingEnabled, forKey: Keys.queueingEnabled) }
    }

    @Published var maximumActiveDownloads: Int {
        didSet { defaults.set(maximumActiveDownloads, forKey: Keys.maximumActiveDownloads) }
    }

    @Published var maximumActiveSeeds: Int {
        didSet { defaults.set(maximumActiveSeeds, forKey: Keys.maximumActiveSeeds) }
    }

    @Published var maximumActiveTorrents: Int {
        didSet { defaults.set(maximumActiveTorrents, forKey: Keys.maximumActiveTorrents) }
    }

    @Published var ignoreSlowTorrents: Bool {
        didSet { defaults.set(ignoreSlowTorrents, forKey: Keys.ignoreSlowTorrents) }
    }

    @Published var networkInterface: String {
        didSet { defaults.set(networkInterface, forKey: Keys.networkInterface) }
    }
    @Published var transportMode: TorrentTransportMode {
        didSet { defaults.set(transportMode.rawValue, forKey: Keys.transportMode) }
    }
    @Published var encryptionMode: TorrentEncryptionMode {
        didSet { defaults.set(encryptionMode.rawValue, forKey: Keys.encryptionMode) }
    }
    @Published var diskIOBackend: TorrentDiskIOBackend {
        didSet { defaults.set(diskIOBackend.rawValue, forKey: Keys.diskIOBackend) }
    }
    @Published var diskIOReadMode: Int {
        didSet { defaults.set(diskIOReadMode, forKey: Keys.diskIOReadMode) }
    }
    @Published var diskIOWriteMode: Int {
        didSet { defaults.set(diskIOWriteMode, forKey: Keys.diskIOWriteMode) }
    }
    @Published var preallocateFiles: Bool {
        didSet { defaults.set(preallocateFiles, forKey: Keys.preallocateFiles) }
    }
    @Published var outgoingPortStart: Int {
        didSet { defaults.set(outgoingPortStart, forKey: Keys.outgoingPortStart) }
    }
    @Published var outgoingPortEnd: Int {
        didSet { defaults.set(outgoingPortEnd, forKey: Keys.outgoingPortEnd) }
    }
    /// Tracker URLs to add to hash-only magnets. Keep this as a newline-
    /// separated string so the setting can be pasted directly from another
    /// torrent client's tracker list.
    @Published var additionalTrackerURLs: String {
        didSet { defaults.set(additionalTrackerURLs, forKey: Keys.additionalTrackerURLs) }
    }
    @Published var isDHTEnabled: Bool { didSet { defaults.set(isDHTEnabled, forKey: Keys.dhtEnabled) } }
    @Published var isPeerExchangeEnabled: Bool { didSet { defaults.set(isPeerExchangeEnabled, forKey: Keys.peerExchangeEnabled) } }
    @Published var isLocalPeerDiscoveryEnabled: Bool { didSet { defaults.set(isLocalPeerDiscoveryEnabled, forKey: Keys.localPeerDiscoveryEnabled) } }
    @Published var isUPnPEnabled: Bool { didSet { defaults.set(isUPnPEnabled, forKey: Keys.upnpEnabled) } }
    @Published var isNATPMPEnabled: Bool { didSet { defaults.set(isNATPMPEnabled, forKey: Keys.natpmpEnabled) } }
    @Published var proxyType: TorrentProxyType { didSet { defaults.set(proxyType.rawValue, forKey: Keys.proxyType) } }
    @Published var proxyHost: String { didSet { defaults.set(proxyHost, forKey: Keys.proxyHost) } }
    @Published var proxyPort: Int { didSet { defaults.set(proxyPort, forKey: Keys.proxyPort) } }
    @Published var proxyUsername: String { didSet { defaults.set(proxyUsername, forKey: Keys.proxyUsername) } }
    @Published var proxyPassword: String { didSet { Self.storeProxyPassword(proxyPassword) } }
    @Published var proxyPeerConnections: Bool { didSet { defaults.set(proxyPeerConnections, forKey: Keys.proxyPeerConnections) } }
    @Published var proxyHostnames: Bool { didSet { defaults.set(proxyHostnames, forKey: Keys.proxyHostnames) } }
    @Published var blockedIPRanges: String { didSet { defaults.set(blockedIPRanges, forKey: Keys.blockedIPRanges) } }
    @Published var proxyTrackerConnections: Bool { didSet { defaults.set(proxyTrackerConnections, forKey: Keys.proxyTrackerConnections) } }
    @Published var anonymousMode: Bool { didSet { defaults.set(anonymousMode, forKey: Keys.anonymousMode) } }
    @Published var ssrfMitigationEnabled: Bool { didSet { defaults.set(ssrfMitigationEnabled, forKey: Keys.ssrfMitigationEnabled) } }
    @Published var validateHTTPSTrackers: Bool { didSet { defaults.set(validateHTTPSTrackers, forKey: Keys.validateHTTPSTrackers) } }
    @Published var blockPrivilegedPeerPorts: Bool { didSet { defaults.set(blockPrivilegedPeerPorts, forKey: Keys.blockPrivilegedPeerPorts) } }
    @Published var allowMultipleConnectionsPerIP: Bool { didSet { defaults.set(allowMultipleConnectionsPerIP, forKey: Keys.allowMultipleConnectionsPerIP) } }
    @Published var isI2PEnabled: Bool { didSet { defaults.set(isI2PEnabled, forKey: Keys.i2pEnabled) } }
    @Published var i2pHost: String { didSet { defaults.set(i2pHost, forKey: Keys.i2pHost) } }
    @Published var i2pPort: Int { didSet { defaults.set(i2pPort, forKey: Keys.i2pPort) } }
    @Published var i2pMixedMode: Bool { didSet { defaults.set(i2pMixedMode, forKey: Keys.i2pMixedMode) } }
    @Published var isRemoteControlEnabled: Bool { didSet { defaults.set(isRemoteControlEnabled, forKey: Keys.remoteControlEnabled) } }

    @Published var bandwidthSchedule: BandwidthSchedule {
        didSet { defaults.set(try? JSONEncoder().encode(bandwidthSchedule), forKey: "network.preferences.bandwidthSchedule") }
    }
    @Published var remoteControlAllowsLAN: Bool {
        didSet { defaults.set(remoteControlAllowsLAN, forKey: "remote.preferences.allowsLAN") }
    }
    @Published var remoteControlPort: Int {
        didSet { defaults.set(remoteControlPort, forKey: "remote.preferences.port") }
    }

    @Published var remoteControlUsesHTTPS: Bool {
        didSet { defaults.set(remoteControlUsesHTTPS, forKey: "remote.preferences.https") }
    }
    @Published var remoteControlTLSIdentity: RemoteTLSIdentity? {
        didSet { defaults.set(try? JSONEncoder().encode(remoteControlTLSIdentity), forKey: "remote.preferences.tlsIdentity") }
    }
    @Published var remoteControlHostname: String {
        didSet { defaults.set(remoteControlHostname, forKey: "remote.preferences.hostname") }
    }

    @Published var remoteWebUIBookmark: Data? {
        didSet { defaults.set(remoteWebUIBookmark, forKey: "remote.preferences.webUIBookmark") }
    }

    private let defaults: UserDefaults
    private enum Keys {
        static let seedingEnabled = "seeding.preferences.enabled"
        static let notificationsEnabled = "preferences.notifications.enabled"
        static let completionSoundEnabled = "preferences.notifications.soundEnabled"
        static let listenPort = "network.preferences.listenPort"
        static let globalConnectionLimit = "network.preferences.globalConnectionLimit"
        static let perTorrentConnectionLimit = "network.preferences.perTorrentConnectionLimit"
        static let downloadLimitMBps = "network.preferences.downloadLimitMBps"
        static let uploadLimitMBps = "network.preferences.uploadLimitMBps"
        static let globalUploadSlots = "network.preferences.globalUploadSlots"
        static let perTorrentUploadSlots = "network.preferences.perTorrentUploadSlots"
        static let queueingEnabled = "network.preferences.queueingEnabled"
        static let maximumActiveDownloads = "network.preferences.maximumActiveDownloads"
        static let maximumActiveSeeds = "network.preferences.maximumActiveSeeds"
        static let maximumActiveTorrents = "network.preferences.maximumActiveTorrents"
        static let ignoreSlowTorrents = "network.preferences.ignoreSlowTorrents"
        static let networkInterface = "network.preferences.interface"
        static let transportMode = "network.preferences.transportMode"
        static let encryptionMode = "network.preferences.encryptionMode"
        static let diskIOBackend = "network.preferences.diskIOBackend"
        static let diskIOReadMode = "network.preferences.diskIOReadMode"
        static let diskIOWriteMode = "network.preferences.diskIOWriteMode"
        static let preallocateFiles = "network.preferences.preallocateFiles"
        static let outgoingPortStart = "network.preferences.outgoingPortStart"
        static let outgoingPortEnd = "network.preferences.outgoingPortEnd"
        static let additionalTrackerURLs = "network.preferences.additionalTrackerURLs"
        static let dhtEnabled = "network.preferences.dhtEnabled"
        static let peerExchangeEnabled = "network.preferences.peerExchangeEnabled"
        static let localPeerDiscoveryEnabled = "network.preferences.localPeerDiscoveryEnabled"
        static let upnpEnabled = "network.preferences.upnpEnabled"
        static let natpmpEnabled = "network.preferences.natpmpEnabled"
        static let proxyType = "network.preferences.proxyType"
        static let proxyHost = "network.preferences.proxyHost"
        static let proxyPort = "network.preferences.proxyPort"
        static let proxyUsername = "network.preferences.proxyUsername"
        static let proxyPeerConnections = "network.preferences.proxyPeerConnections"
        static let proxyHostnames = "network.preferences.proxyHostnames"
        static let blockedIPRanges = "network.preferences.blockedIPRanges"
        static let proxyTrackerConnections = "network.preferences.proxyTrackerConnections"
        static let anonymousMode = "network.preferences.anonymousMode"
        static let ssrfMitigationEnabled = "network.preferences.ssrfMitigationEnabled"
        static let validateHTTPSTrackers = "network.preferences.validateHTTPSTrackers"
        static let blockPrivilegedPeerPorts = "network.preferences.blockPrivilegedPeerPorts"
        static let allowMultipleConnectionsPerIP = "network.preferences.allowMultipleConnectionsPerIP"
        static let networkDefaultsVersion = "network.preferences.defaultsVersion"
        static let i2pEnabled = "network.preferences.i2pEnabled"
        static let i2pHost = "network.preferences.i2pHost"
        static let i2pPort = "network.preferences.i2pPort"
        static let i2pMixedMode = "network.preferences.i2pMixedMode"
        static let remoteControlEnabled = "automation.remoteControlEnabled"
    }

    // Keep the original Keychain service so saved proxy credentials survive the rebrand.
    private static let proxyPasswordService = "com.torrentscout.proxy"

    /// Tracker defaults change over time. Keep the retired sets here only so
    /// an upgrade can remove them from existing preferences without touching
    /// a list the user entered themselves.
    private static let legacyDefaultTrackerSets: [Set<String>] = [
        Set([
            "udp://tracker.internetwarriors.net:1337/announce",
            "udp://tracker.opentrackr.org:1337/announce",
            "udp://p4p.arenabg.ch:1337/announce",
            "udp://tracker.openbittorrent.com:6969/announce",
            "udp://www.torrent.eu.org:451/announce",
            "udp://tracker.torrent.eu.org:451/announce",
            "udp://retracker.lanta-net.ru:2710/announce",
            "udp://open.stealth.si:80/announce",
            "udp://exodus.desync.com:6969/announce",
            "udp://tracker.tiny-vps.com:6969/announce"
        ].map { $0.lowercased() }),
        Set([
            "udp://tracker.opentrackr.org:1337/announce",
            "udp://tracker.openbittorrent.com:6969/announce",
            "udp://tracker.coppersurfer.tk:6969/announce",
            "udp://9.rarbg.to:2710/announce",
            "udp://tracker.torrent.eu.org:451/announce"
        ].map { $0.lowercased() })
    ]

    /// Removes tracker URLs that were shipped as application defaults. This
    /// also handles lists that mixed the old defaults with the newer list, as
    /// happened for users who upgraded between tracker-list revisions. Any
    /// URL not known to be an application default is preserved verbatim.
    private static func removingBuiltInDefaults(from value: String) -> String {
        var builtInURLs = legacyDefaultTrackerSets.reduce(into: Set<String>()) { result, set in
            result.formUnion(set)
        }
        // Include the current snapshot as well as older snapshots so a prior
        // version that persisted the curated list is migrated back to the
        // user-only field.
        builtInURLs.formUnion(defaultMagnetTrackers.map { $0.lowercased() })
        let retained = value.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && !builtInURLs.contains($0.lowercased()) }
        return retained.joined(separator: "\n")
    }

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        if defaults.object(forKey: Keys.seedingEnabled) == nil {
            defaults.set(true, forKey: Keys.seedingEnabled)
        }
        if defaults.object(forKey: Keys.notificationsEnabled) == nil {
            defaults.set(false, forKey: Keys.notificationsEnabled)
        }
        if defaults.object(forKey: Keys.completionSoundEnabled) == nil {
            defaults.set(true, forKey: Keys.completionSoundEnabled)
        }
        if defaults.object(forKey: Keys.listenPort) == nil {
            defaults.set(Int.random(in: 49_152...65_535), forKey: Keys.listenPort)
        }
        let storedTrackers = defaults.string(forKey: Keys.additionalTrackerURLs)
        if storedTrackers == nil || storedTrackers?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            // Keep this field limited to explicit user additions. The
            // refreshed trackers_best list is passed separately to the
            // native session and is applied only by the adaptive fallback.
            defaults.set("", forKey: Keys.additionalTrackerURLs)
        } else {
            let cleanedTrackers = Self.removingBuiltInDefaults(from: storedTrackers ?? "")
            if cleanedTrackers != storedTrackers {
                // Migrate old global defaults once. User-entered trackers are
                // retained, while retired/unavailable shipped trackers are
                // no longer re-added to new torrents.
                defaults.set(cleanedTrackers, forKey: Keys.additionalTrackerURLs)
            }
        }
        if defaults.object(forKey: Keys.globalConnectionLimit) == nil {
            defaults.set(500, forKey: Keys.globalConnectionLimit)
        }
        if defaults.object(forKey: Keys.perTorrentConnectionLimit) == nil {
            defaults.set(100, forKey: Keys.perTorrentConnectionLimit)
        }
        if defaults.object(forKey: Keys.maximumActiveDownloads) == nil {
            defaults.set(3, forKey: Keys.maximumActiveDownloads)
        }
        if defaults.object(forKey: Keys.globalUploadSlots) == nil {
            defaults.set(20, forKey: Keys.globalUploadSlots)
        }
        if defaults.object(forKey: Keys.perTorrentUploadSlots) == nil {
            defaults.set(4, forKey: Keys.perTorrentUploadSlots)
        }
        if defaults.object(forKey: Keys.maximumActiveSeeds) == nil {
            defaults.set(3, forKey: Keys.maximumActiveSeeds)
        }
        if defaults.object(forKey: Keys.maximumActiveTorrents) == nil {
            defaults.set(5, forKey: Keys.maximumActiveTorrents)
        }
        for key in [Keys.dhtEnabled, Keys.peerExchangeEnabled, Keys.localPeerDiscoveryEnabled,
                    Keys.upnpEnabled, Keys.natpmpEnabled, Keys.proxyPeerConnections, Keys.proxyHostnames,
                    Keys.proxyTrackerConnections, Keys.ssrfMitigationEnabled, Keys.validateHTTPSTrackers]
        where defaults.object(forKey: key) == nil {
            defaults.set(true, forKey: key)
        }
        // Earlier builds enabled the stricter privileged-port filter by
        // default, which made some announced peers visible but impossible to
        // connect to. Migrate that old default once; users can still opt back
        // into the filter from Settings.
        if defaults.integer(forKey: Keys.networkDefaultsVersion) < 1 {
            defaults.set(false, forKey: Keys.blockPrivilegedPeerPorts)
            defaults.set(1, forKey: Keys.networkDefaultsVersion)
        }
        self.isSeedingEnabled = defaults.bool(forKey: Keys.seedingEnabled)
        self.areNotificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        self.isCompletionSoundEnabled = defaults.bool(forKey: Keys.completionSoundEnabled)
        self.listenPort = min(max(defaults.integer(forKey: Keys.listenPort), 49_152), 65_535)
        self.globalConnectionLimit = min(max(defaults.integer(forKey: Keys.globalConnectionLimit), 50), 1_000)
        self.perTorrentConnectionLimit = min(max(defaults.integer(forKey: Keys.perTorrentConnectionLimit), 10), 500)
        self.downloadLimitMBps = max(defaults.integer(forKey: Keys.downloadLimitMBps), 0)
        self.uploadLimitMBps = max(defaults.integer(forKey: Keys.uploadLimitMBps), 0)
        self.globalUploadSlots = min(max(defaults.integer(forKey: Keys.globalUploadSlots), 1), 200)
        self.perTorrentUploadSlots = min(max(defaults.integer(forKey: Keys.perTorrentUploadSlots), 1), 50)
        self.isQueueingEnabled = defaults.bool(forKey: Keys.queueingEnabled)
        self.maximumActiveDownloads = min(max(defaults.integer(forKey: Keys.maximumActiveDownloads), 1), 50)
        self.maximumActiveSeeds = min(max(defaults.integer(forKey: Keys.maximumActiveSeeds), 1), 50)
        self.maximumActiveTorrents = min(max(defaults.integer(forKey: Keys.maximumActiveTorrents), 1), 100)
        self.ignoreSlowTorrents = defaults.bool(forKey: Keys.ignoreSlowTorrents)
        self.networkInterface = defaults.string(forKey: Keys.networkInterface) ?? ""
        self.transportMode = TorrentTransportMode(rawValue: defaults.string(forKey: Keys.transportMode) ?? "") ?? .both
        self.encryptionMode = TorrentEncryptionMode(rawValue: defaults.string(forKey: Keys.encryptionMode) ?? "") ?? .enabled
        self.diskIOBackend = TorrentDiskIOBackend(rawValue: defaults.string(forKey: Keys.diskIOBackend) ?? "") ?? .automatic
        self.diskIOReadMode = min(max(defaults.object(forKey: Keys.diskIOReadMode) == nil ? 0 : defaults.integer(forKey: Keys.diskIOReadMode), 0), 2)
        self.diskIOWriteMode = min(max(defaults.object(forKey: Keys.diskIOWriteMode) == nil ? 0 : defaults.integer(forKey: Keys.diskIOWriteMode), 0), 3)
        self.preallocateFiles = defaults.bool(forKey: Keys.preallocateFiles)
        self.outgoingPortStart = min(max(defaults.integer(forKey: Keys.outgoingPortStart), 0), 65_535)
        self.outgoingPortEnd = min(max(defaults.integer(forKey: Keys.outgoingPortEnd), 0), 65_535)
        self.additionalTrackerURLs = defaults.string(forKey: Keys.additionalTrackerURLs) ?? ""
        self.isDHTEnabled = defaults.bool(forKey: Keys.dhtEnabled)
        self.isPeerExchangeEnabled = defaults.bool(forKey: Keys.peerExchangeEnabled)
        self.isLocalPeerDiscoveryEnabled = defaults.bool(forKey: Keys.localPeerDiscoveryEnabled)
        self.isUPnPEnabled = defaults.bool(forKey: Keys.upnpEnabled)
        self.isNATPMPEnabled = defaults.bool(forKey: Keys.natpmpEnabled)
        self.proxyType = TorrentProxyType(rawValue: defaults.string(forKey: Keys.proxyType) ?? "") ?? .none
        self.proxyHost = defaults.string(forKey: Keys.proxyHost) ?? ""
        self.proxyPort = min(max(defaults.integer(forKey: Keys.proxyPort), 0), 65_535)
        self.proxyUsername = defaults.string(forKey: Keys.proxyUsername) ?? ""
        self.proxyPassword = Self.loadProxyPassword()
        self.proxyPeerConnections = defaults.bool(forKey: Keys.proxyPeerConnections)
        self.proxyHostnames = defaults.bool(forKey: Keys.proxyHostnames)
        self.blockedIPRanges = defaults.string(forKey: Keys.blockedIPRanges) ?? ""
        self.proxyTrackerConnections = defaults.bool(forKey: Keys.proxyTrackerConnections)
        self.anonymousMode = defaults.bool(forKey: Keys.anonymousMode)
        self.ssrfMitigationEnabled = defaults.bool(forKey: Keys.ssrfMitigationEnabled)
        self.validateHTTPSTrackers = defaults.bool(forKey: Keys.validateHTTPSTrackers)
        self.blockPrivilegedPeerPorts = defaults.bool(forKey: Keys.blockPrivilegedPeerPorts)
        self.allowMultipleConnectionsPerIP = defaults.bool(forKey: Keys.allowMultipleConnectionsPerIP)
        self.isI2PEnabled = defaults.bool(forKey: Keys.i2pEnabled)
        self.i2pHost = defaults.string(forKey: Keys.i2pHost) ?? "127.0.0.1"
        self.i2pPort = defaults.object(forKey: Keys.i2pPort) == nil ? 7656 : min(max(defaults.integer(forKey: Keys.i2pPort), 1), 65_535)
        self.i2pMixedMode = defaults.bool(forKey: Keys.i2pMixedMode)
        self.isRemoteControlEnabled = defaults.bool(forKey: Keys.remoteControlEnabled)
        self.bandwidthSchedule = defaults.data(forKey: "network.preferences.bandwidthSchedule")
            .flatMap { try? JSONDecoder().decode(BandwidthSchedule.self, from: $0) } ?? BandwidthSchedule()
        self.remoteControlAllowsLAN = defaults.bool(forKey: "remote.preferences.allowsLAN")
        let port = defaults.object(forKey: "remote.preferences.port") as? Int ?? 8555
        self.remoteControlPort = min(max(port, 1024), 65535)
        self.remoteControlUsesHTTPS = defaults.bool(forKey: "remote.preferences.https")
        self.remoteControlTLSIdentity = defaults.data(forKey: "remote.preferences.tlsIdentity")
            .flatMap { try? JSONDecoder().decode(RemoteTLSIdentity.self, from: $0) }
        self.remoteControlHostname = defaults.string(forKey: "remote.preferences.hostname") ?? ""
        self.remoteWebUIBookmark = defaults.data(forKey: "remote.preferences.webUIBookmark")
    }

    private func persistSeeding() {
        defaults.set(isSeedingEnabled, forKey: Keys.seedingEnabled)
    }

    private func persistNotifications() {
        defaults.set(areNotificationsEnabled, forKey: Keys.notificationsEnabled)
    }

    var networkConfiguration: WebTorrentSession.NetworkConfiguration { networkConfiguration(at: Date()) }

    func networkConfiguration(at date: Date, calendar: Calendar = .current) -> WebTorrentSession.NetworkConfiguration {
        let scheduled = bandwidthSchedule.isActive(at: date, calendar: calendar)
        return WebTorrentSession.NetworkConfiguration(
            listenPort: listenPort,
            globalConnectionLimit: globalConnectionLimit,
            perTorrentConnectionLimit: perTorrentConnectionLimit,
            downloadLimitBytesPerSecond: (scheduled ? min(max(bandwidthSchedule.downloadLimitMBps, 0), 1000) : downloadLimitMBps) * 1_000_000,
            uploadLimitBytesPerSecond: (scheduled ? min(max(bandwidthSchedule.uploadLimitMBps, 0), 1000) : uploadLimitMBps) * 1_000_000,
            globalUploadSlots: globalUploadSlots,
            perTorrentUploadSlots: perTorrentUploadSlots,
            queueingEnabled: isQueueingEnabled,
            maximumActiveDownloads: maximumActiveDownloads,
            maximumActiveSeeds: maximumActiveSeeds,
            maximumActiveTorrents: maximumActiveTorrents,
            ignoreSlowTorrents: ignoreSlowTorrents,
            networkInterface: networkInterface.trimmingCharacters(in: .whitespacesAndNewlines),
            transportMode: transportMode.rawValue,
            encryptionMode: encryptionMode.rawValue,
            diskIOBackend: diskIOBackend.rawValue,
            diskIOReadMode: diskIOReadMode,
            diskIOWriteMode: diskIOWriteMode,
            preallocateFiles: preallocateFiles,
            outgoingPortStart: outgoingPortStart,
            outgoingPortEnd: outgoingPortEnd,
            additionalTrackerURLs: Self.normalizedTrackerURLs(from: additionalTrackerURLs),
            adaptiveTrackerURLs: TrackersBestStore.shared.current(),
            dhtEnabled: isDHTEnabled,
            peerExchangeEnabled: isPeerExchangeEnabled,
            localPeerDiscoveryEnabled: isLocalPeerDiscoveryEnabled,
            upnpEnabled: isUPnPEnabled,
            natpmpEnabled: isNATPMPEnabled,
            proxyType: proxyType.rawValue,
            proxyHost: proxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
            proxyPort: proxyPort,
            proxyUsername: proxyUsername,
            proxyPassword: proxyPassword,
            proxyPeerConnections: proxyPeerConnections,
            proxyHostnames: proxyHostnames,
            proxyTrackerConnections: proxyTrackerConnections,
            anonymousMode: anonymousMode,
            ssrfMitigationEnabled: ssrfMitigationEnabled,
            validateHTTPSTrackers: validateHTTPSTrackers,
            blockPrivilegedPeerPorts: blockPrivilegedPeerPorts,
            allowMultipleConnectionsPerIP: allowMultipleConnectionsPerIP,
            i2pEnabled: isI2PEnabled,
            i2pHost: i2pHost.trimmingCharacters(in: .whitespacesAndNewlines),
            i2pPort: i2pPort,
            i2pMixedMode: i2pMixedMode,
            blockedIPRanges: blockedIPRanges.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    private static func normalizedTrackerURLs(from raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { value in
                guard !value.isEmpty,
                      let url = URL(string: value),
                      let scheme = url.scheme?.lowercased(),
                      ["udp", "http", "https"].contains(scheme),
                      url.host != nil else { return false }
                return seen.insert(value.lowercased()).inserted
            }
    }

    private static func loadProxyPassword() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: proxyPasswordService,
                                    kSecAttrAccount as String: "default",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func storeProxyPassword(_ password: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: proxyPasswordService,
                                   kSecAttrAccount as String: "default"]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
