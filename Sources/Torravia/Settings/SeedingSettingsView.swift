import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case automation
    case transfers
    case network
    case search

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .automation: "Automation"
        case .transfers: "Transfers"
        case .network: "Network"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .automation: "clock.arrow.circlepath"
        case .transfers: "arrow.up.arrow.down"
        case .network: "network"
        case .search: "magnifyingglass"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Downloads, notifications, and everyday behavior"
        case .automation: "Watched folders, RSS feeds, and remote control"
        case .transfers: "Bandwidth, connections, queues, and disk usage"
        case .network: "Peer discovery, privacy, proxy, and diagnostics"
        case .search: "Choose the websites Torravia searches"
        }
    }
}

struct SeedingSettingsView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var preferences: SeedingPreferencesStore
    @EnvironmentObject private var searchPreferences: SearchPreferencesStore
    @EnvironmentObject private var downloadLocation: DownloadLocationStore
    @EnvironmentObject private var downloadsVM: DownloadsViewModel
    @EnvironmentObject private var automation: DownloadAutomationStore
    @EnvironmentObject private var providerHealth: ProviderHealthStore
    @State private var newRSSFeed = ""
    @State private var newRSSInclude = ""
    @State private var newRSSExclude = ""
    @State private var newRSSCategory = ""
    @State private var newRSSMatchAll = false
    @State private var newRSSMaxItems = "50"
    @State private var newRSSTags = ""
    @State private var newRSSStartPaused = false
    @State private var newRSSSequential = false
    @State private var newRSSQueuePriority = 0
    @FocusState private var focusedField: SettingsField?
    let category: SettingsCategory

    init(category: SettingsCategory = .general) {
        self.category = category
    }

    private enum SettingsField: Hashable {
        case rssFeed
    }

    private let spanishSites = TorrentSearchSite.spanishSites

    var body: some View {
        Form {
            if category == .general {
            Section("Seeding") {
                Toggle("Enable seeding after downloads complete", isOn: $preferences.isSeedingEnabled)
                    .toggleStyle(.switch)
                    .settingsRowAppearance()
            }

            Section("Notifications") {
                Toggle("Send notifications when downloads finish", isOn: $preferences.areNotificationsEnabled)
                    .toggleStyle(.switch)
                    .settingsRowAppearance()
                Toggle("Play a sound when downloads finish", isOn: $preferences.isCompletionSoundEnabled)
                    .toggleStyle(.switch)
                    .settingsRowAppearance()
            }

            Section("Downloads") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(downloadLocation.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    HStack {
                        Button("Choose Location…") {
                            downloadLocation.chooseLocation()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.primary)
                        .foregroundColor(.primary)

                        Spacer(minLength: 0)

                        Button("Use System Default") {
                            downloadLocation.resetToSystemDownloads()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.primary)
                        .foregroundColor(.primary)
                        .disabled(downloadLocation.locationURL == nil)
                    }
                }
                .settingsRowAppearance()
                .accessibilityElement(children: .contain)
            }
            }

            if category == .automation {
            Section("Automation") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Watched folder")
                        .font(.subheadline.weight(.semibold))
                    Text(automation.watchedFolderDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack {
                        Button("Choose Folder…") { automation.chooseWatchedFolder() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.primary)
                            .foregroundColor(.primary)
                        Spacer(minLength: 0)
                        Button("Disable") { automation.resetWatchedFolder() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.primary)
                            .foregroundColor(.primary)
                            .disabled(automation.watchedFolderURL == nil)
                    }
                    Text("Torravia imports new .torrent files from this folder and keeps retrying files that are temporarily unavailable.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Divider()

                    HStack {
                        Text("RSS feeds")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Refresh Now") { downloadsVM.refreshRSSFeeds() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.primary)
                            .foregroundColor(.primary)
                            .disabled(automation.rssFeedURLs.isEmpty)
                    }
                    LabeledContent("Feed URL") {
                        HStack {
                            TextField("", text: $newRSSFeed, prompt: Text("https://example.com/feed.xml"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .foregroundStyle(.primary)
                                .focused($focusedField, equals: .rssFeed)
                            Button("Add") {
                                automation.addRSSRule(feedURL: newRSSFeed,
                                                      include: newRSSInclude,
                                                      exclude: newRSSExclude,
                                                      category: newRSSCategory,
                                                      matchAll: newRSSMatchAll,
                                                      maxItemsPerPoll: Int(newRSSMaxItems) ?? 50,
                                                      tags: newRSSTags.split(separator: ",").map(String.init),
                                                      startPaused: newRSSStartPaused,
                                                      sequential: newRSSSequential,
                                                      queuePriority: newRSSQueuePriority)
                                newRSSFeed = ""
                                newRSSInclude = ""
                                newRSSExclude = ""
                                newRSSCategory = ""
                                newRSSMatchAll = false
                                newRSSMaxItems = "50"
                                newRSSTags = ""
                                newRSSStartPaused = false
                                newRSSSequential = false
                                newRSSQueuePriority = 0
                            }
                            .disabled(newRSSFeed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    TextField("Include title regex (comma-separated, optional)", text: $newRSSInclude)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(.primary)
                    TextField("Exclude title regex (comma-separated, optional)", text: $newRSSExclude)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(.primary)
                    TextField("Category folder (optional)", text: $newRSSCategory)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(.primary)
                    Toggle("Require every include pattern", isOn: $newRSSMatchAll)
                        .toggleStyle(.checkbox)
                    TextField("Maximum imports per poll", text: $newRSSMaxItems)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(.primary)
                    TextField("Tags (comma-separated)", text: $newRSSTags)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(.primary)
                    HStack {
                        Toggle("Start paused", isOn: $newRSSStartPaused)
                            .toggleStyle(.checkbox)
                        Toggle("Sequential", isOn: $newRSSSequential)
                            .toggleStyle(.checkbox)
                        Picker("Queue", selection: $newRSSQueuePriority) {
                            Text("Normal").tag(0)
                            Text("Top").tag(1)
                            Text("Bottom").tag(-1)
                        }
                        .frame(width: 150)
                    }
                    Text("Rules support case-insensitive regex filters, all-pattern matching, tags, queue placement, sequential mode, start-paused mode, and an import cap. Failed items remain eligible for the next poll.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if automation.rssFeedURLs.isEmpty {
                        Text("No feeds configured. RSS items may contain magnet links or .torrent enclosures.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(automation.rssRules) { rule in
                            HStack(spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { rule.enabled },
                                    set: { enabled in
                                        var updated = rule
                                        updated.enabled = enabled
                                        automation.updateRSSRule(updated)
                                    }
                                ))
                                .labelsHidden()
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.feedURL)
                                        .opacity(0)
                                        .accessibilityHidden(true)
                                    let details = [
                                        rule.include.isEmpty ? nil : "include: \(rule.include)",
                                        rule.exclude.isEmpty ? nil : "exclude: \(rule.exclude)",
                                        rule.category.isEmpty ? nil : "category: \(rule.category)",
                                        rule.matchAll ? "all include patterns" : nil,
                                        "max \(rule.maxItemsPerPoll) per poll",
                                        rule.tags.isEmpty ? nil : "tags: \(rule.tags.joined(separator: ", "))",
                                        rule.startPaused ? "starts paused" : nil,
                                        rule.sequential ? "sequential" : nil,
                                        rule.queuePriority == 1 ? "queue top" : rule.queuePriority == -1 ? "queue bottom" : nil
                                    ].compactMap { $0 }.joined(separator: " · ")
                                    if !details.isEmpty {
                                        Text(details)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Button {
                                    if let index = automation.rssFeedURLs.firstIndex(where: {
                                        $0.caseInsensitiveCompare(rule.feedURL) == .orderedSame
                                    }) {
                                        automation.removeRSSFeed(at: IndexSet(integer: index))
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove feed")
                            }
                        }
                    }
                }
                .settingsRowAppearance()
            }

            Section("Remote control") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable browser control", isOn: $preferences.isRemoteControlEnabled)
                        .toggleStyle(.switch)
                    if preferences.isRemoteControlEnabled {
                        if let url = downloadsVM.remoteControlURL {
                                Text(url.absoluteString)
                                    .font(.caption.monospaced())
                                    .opacity(0)
                                    .accessibilityHidden(true)
                                    .lineLimit(2)
                        } else {
                            Text("Starting browser control…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Open browser control from Settings → Automation. Access from other devices is optional. Configure HTTPS and import a certificate in Automation settings to encrypt browser and API traffic; HTTP should be used only on a trusted local network or VPN. Browser controls include downloads, files, RSS rules, categories, tags, bandwidth scheduling, trackers, and peers.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .settingsRowAppearance()
            }
            }

            if category == .transfers {
            Section("Bandwidth & connections") {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper("Listening port: \(preferences.listenPort)",
                            value: boundedBinding(\.listenPort, range: 49_152...65_535),
                            in: 49_152...65_535)

                    Stepper("Global peer limit: \(preferences.globalConnectionLimit)",
                            value: boundedBinding(\.globalConnectionLimit, range: 50...1_000),
                            in: 50...1_000,
                            step: 50)

                    Stepper("Per-torrent peer limit: \(preferences.perTorrentConnectionLimit)",
                            value: boundedBinding(\.perTorrentConnectionLimit, range: 10...500),
                            in: 10...500,
                            step: 10)

                    Stepper("Download limit: \(rateLimitDescription(preferences.downloadLimitMBps))",
                            value: boundedBinding(\.downloadLimitMBps, range: 0...1_000),
                            in: 0...1_000,
                            step: 5)

                    Stepper("Upload limit: \(rateLimitDescription(preferences.uploadLimitMBps))",
                            value: boundedBinding(\.uploadLimitMBps, range: 0...1_000),
                            in: 0...1_000,
                            step: 5)

                    Stepper("Global upload slots: \(preferences.globalUploadSlots)",
                            value: boundedBinding(\.globalUploadSlots, range: 1...200),
                            in: 1...200)

                    Stepper("Per-torrent upload slots: \(preferences.perTorrentUploadSlots)",
                            value: boundedBinding(\.perTorrentUploadSlots, range: 1...50),
                            in: 1...50)

                    Picker("Disk I/O backend", selection: $preferences.diskIOBackend) {
                        ForEach(TorrentDiskIOBackend.allCases) { backend in
                            Text(backend.title).tag(backend)
                        }
                    }

                    Picker("Read cache", selection: $preferences.diskIOReadMode) {
                        Text("OS cache").tag(0)
                        Text("Direct I/O").tag(2)
                    }

                    Picker("Write cache", selection: $preferences.diskIOWriteMode) {
                        Text("OS cache").tag(0)
                        Text("Direct I/O").tag(2)
                        Text("Write-through").tag(3)
                    }

                    Toggle("Preallocate files", isOn: $preferences.preallocateFiles)

                    Toggle("Queue downloads", isOn: $preferences.isQueueingEnabled)
                        .toggleStyle(.switch)

                    if preferences.isQueueingEnabled {
                        Stepper("Maximum active downloads: \(preferences.maximumActiveDownloads)",
                                value: boundedBinding(\.maximumActiveDownloads, range: 1...50),
                                in: 1...50)

                        Stepper("Maximum active seeds: \(preferences.maximumActiveSeeds)",
                                value: boundedBinding(\.maximumActiveSeeds, range: 1...50),
                                in: 1...50)

                        Stepper("Maximum active torrents: \(preferences.maximumActiveTorrents)",
                                value: boundedBinding(\.maximumActiveTorrents, range: 1...100),
                                in: 1...100)

                        Toggle("Don't count slow torrents", isOn: $preferences.ignoreSlowTorrents)
                            .toggleStyle(.switch)
                    }

                    Text("0 MB/s means unlimited. Upload slots control how many peers can receive data simultaneously. Changes apply immediately and persist across launches.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("Automatic selects a safe libtorrent backend; changing the backend applies the next time the native helper starts. Cache modes and adaptive disk queues apply immediately.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .settingsRowAppearance()
            }
            }

            if category == .network {
            Section("Network & privacy") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Peer transport", selection: $preferences.transportMode) {
                        ForEach(TorrentTransportMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    Picker("Connection encryption", selection: $preferences.encryptionMode) {
                        ForEach(TorrentEncryptionMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    TextField("Network interface (auto, all, en0, or utun4)", text: $preferences.networkInterface)
                        .foregroundStyle(.primary)

                    Toggle("Distributed Hash Table (DHT)", isOn: $preferences.isDHTEnabled)
                    Toggle("Peer Exchange (PeX)", isOn: $preferences.isPeerExchangeEnabled)
                    Toggle("Local Peer Discovery", isOn: $preferences.isLocalPeerDiscoveryEnabled)
                    Toggle("Automatic UPnP port mapping", isOn: $preferences.isUPnPEnabled)
                    Toggle("Automatic NAT-PMP port mapping", isOn: $preferences.isNATPMPEnabled)
                    Toggle("Anonymous mode", isOn: $preferences.anonymousMode)
                    Toggle("Protect against tracker SSRF", isOn: $preferences.ssrfMitigationEnabled)
                    Toggle("Validate HTTPS tracker certificates", isOn: $preferences.validateHTTPSTrackers)
                    Toggle("Block peers on privileged ports", isOn: $preferences.blockPrivilegedPeerPorts)
                    Toggle("Allow multiple connections from one IP", isOn: $preferences.allowMultipleConnectionsPerIP)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Additional trackers")
                            .font(.subheadline.weight(.semibold))
                        TextEditor(text: $preferences.additionalTrackerURLs)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(minHeight: 74)
                        Text("One UDP, HTTP, or HTTPS tracker URL per line. These are added to hash-only magnets and existing torrents without removing their original announce list. Paste the same tracker list used by the other client for a fair comparison.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Enable I2P through a SAM bridge", isOn: $preferences.isI2PEnabled)
                    if preferences.isI2PEnabled {
                        TextField("I2P SAM host", text: $preferences.i2pHost)
                            .foregroundStyle(.primary)
                        Stepper("I2P SAM port: \(preferences.i2pPort)",
                                value: boundedBinding(\.i2pPort, range: 1...65_535), in: 1...65_535)
                        Toggle("Allow mixed I2P and public peers", isOn: $preferences.i2pMixedMode)
                    }

                    Stepper("Outgoing port start: \(preferences.outgoingPortStart == 0 ? "Automatic" : String(preferences.outgoingPortStart))",
                            value: boundedBinding(\.outgoingPortStart, range: 0...65_535), in: 0...65_535)
                    Stepper("Outgoing port end: \(preferences.outgoingPortEnd == 0 ? "Automatic" : String(preferences.outgoingPortEnd))",
                            value: boundedBinding(\.outgoingPortEnd, range: 0...65_535), in: 0...65_535)

                    Text("Leave the interface empty for automatic physical adapters. To route torrents through a VPN, enter its interface (for example utun4 or tun0); invalid interfaces are rejected instead of silently using another route.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .settingsRowAppearance()
            }

            Section("Proxy") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Proxy type", selection: $preferences.proxyType) {
                        ForEach(TorrentProxyType.allCases) { type in Text(type.title).tag(type) }
                    }
                    if preferences.proxyType != .none {
                        TextField("Host", text: $preferences.proxyHost)
                            .foregroundStyle(.primary)
                        Stepper("Port: \(preferences.proxyPort)",
                                value: boundedBinding(\.proxyPort, range: 0...65_535), in: 0...65_535)
                        TextField("Username (optional)", text: $preferences.proxyUsername)
                            .foregroundStyle(.primary)
                        SecureField("Password (stored in Keychain)", text: $preferences.proxyPassword)
                            .foregroundStyle(.primary)
                        Toggle("Proxy peer connections", isOn: $preferences.proxyPeerConnections)
                        Toggle("Proxy tracker connections", isOn: $preferences.proxyTrackerConnections)
                        Toggle("Resolve hostnames through proxy", isOn: $preferences.proxyHostnames)
                    }
                }
                .toggleStyle(.switch)
                .settingsRowAppearance()
            }

            Section("IP filter") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $preferences.blockedIPRanges)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(minHeight: 74)
                    Text("One blocked IP, CIDR, or start-end range per line. Lines beginning with # are ignored. The filter also applies to trackers.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .settingsRowAppearance()
            }

            }

            if category == .search {
            Section("Search websites") {
                actionsBar()
                providerHealthSummary

                let generalSites = orderedGeneralSites()
                ForEach(generalSites, id: \.rawValue) { site in
                    siteToggle(for: site)
                }
            }

            if !spanishSites.isEmpty {
                Section("Spanish websites") {
                    ForEach(orderedSpanishSites(), id: \.rawValue) { site in
                        siteToggle(for: site)
                    }
                }
            }
            }
        }
        .formStyle(.grouped)
        .modifier(TransparentFormBackground())
        .onAppear {
            focusedField = nil
            // SwiftUI may assign the first editable control as the window's
            // initial responder after the form appears. Clear that assignment
            // on the next run-loop turn so settings opens without a selected
            // text field while preserving normal click-to-focus behavior.
            DispatchQueue.main.async {
                focusedField = nil
            }
        }
        .textSelection(.enabled)
    }

    private func rateLimitDescription(_ megabytesPerSecond: Int) -> String {
        megabytesPerSecond == 0 ? "Unlimited" : "\(megabytesPerSecond) MB/s"
    }

    private func boundedBinding(_ keyPath: ReferenceWritableKeyPath<SeedingPreferencesStore, Int>,
                                range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { preferences[keyPath: keyPath] = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    private func diagnosticRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func actionsBar() -> some View {
        HStack(spacing: 12) {
            Button("Select All") {
                searchPreferences.enableAllSites()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .foregroundColor(.primary)
            .disabled(searchPreferences.areAllSitesEnabled)

            Button("Keep One Enabled") {
                searchPreferences.keepOnlyOneSiteEnabled()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .foregroundColor(.primary)
            .disabled(!searchPreferences.canReduceToSingleSite)

            Button("Defaults") {
                searchPreferences.resetToDefaults()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .foregroundColor(.primary)
            .disabled(searchPreferences.enabledSites == TorrentSearchSite.defaultEnabled)

            Spacer(minLength: 0)
        }
        .settingsRowAppearance()
    }

    @ViewBuilder
    private var providerHealthSummary: some View {
        let statuses = TorrentSearchSite.defaultOrder.map { providerHealth.status(for: $0) }
        let onlineCount = statuses.filter(\.isOnline).count
        let offlineCount = statuses.filter {
            $0.detail != nil
        }.count

        HStack(spacing: 8) {
            if providerHealth.isChecking {
                ProgressView()
                    .controlSize(.small)
                Text("Checking provider links…")
            } else if let checkedAt = providerHealth.lastCheckedAt {
                Image(systemName: offlineCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(offlineCount == 0 ? Color.green : Color.orange)
                Text("\(onlineCount) online · \(offlineCount) unavailable · checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
            } else {
                Image(systemName: "questionmark.circle")
                Text("Provider links have not been checked yet")
            }

            Spacer(minLength: 8)

            Button {
                providerHealth.checkAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(providerHealth.isChecking)
            .help("Check provider links now")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .settingsRowAppearance()
    }

    @ViewBuilder
    private func siteToggle(for site: TorrentSearchSite) -> some View {
        let isOnlyEnabled = searchPreferences.enabledSites.count == 1 && searchPreferences.isEnabled(site)
        let healthState = providerHealth.status(for: site)
        let providerURL = providerHealth.link(for: site).map(providerBaseURL(from:))
        let binding = Binding(
            get: { searchPreferences.isEnabled(site) },
            set: { isOn in searchPreferences.set(site, enabled: isOn) }
        )

        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(site.displayName)
                Text(site.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                providerHealthBadge(for: healthState)
                if let baseURL = providerURL {
                    Text(baseURL.absoluteString)
                        .font(.caption2)
                        .opacity(0)
                        .accessibilityHidden(true)
                        .onTapGesture { openURL(baseURL) }
                    .help("Open provider page")
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                if !isOnlyEnabled {
                    binding.wrappedValue.toggle()
                }
            })

            Spacer(minLength: 16)

            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 14, trailing: 0))
        .listRowBackground(Color.clear)
        .disabled(isOnlyEnabled)
        .accessibilityHint("Enable or disable searching \(site.displayName)")
        .accessibilityValue(binding.wrappedValue ? "Enabled" : "Disabled")
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func providerHealthBadge(for state: ProviderHealthState) -> some View {
        if state != .unknown {
            HStack(spacing: 4) {
                Image(systemName: state.symbolName)
                Text(state.label)
                    .foregroundStyle(.clear)
            }
            .font(.caption2)
            .foregroundStyle(providerHealthColor(for: state))
            .help(state.detail ?? state.label)
        }
    }

    private func providerBaseURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    private func providerHealthColor(for state: ProviderHealthState) -> Color {
        switch state {
        case .online:
            return .green
        case .offline, .rateLimited:
            return .orange
        case .checking, .unknown:
            return .secondary
        }
    }

    private func orderedGeneralSites() -> [TorrentSearchSite] {
        let baseOrder = TorrentSearchSite.defaultOrder.filter { !spanishSites.contains($0) }
        let indices = Dictionary(uniqueKeysWithValues: baseOrder.enumerated().map { ($1, $0) })
        let enabled = searchPreferences.enabledSites

        return baseOrder.sorted { lhs, rhs in
            let lhsEnabled = enabled.contains(lhs)
            let rhsEnabled = enabled.contains(rhs)
            if lhsEnabled != rhsEnabled {
                return lhsEnabled
            }
            return indices[lhs, default: 0] < indices[rhs, default: 0]
        }
    }

    private func orderedSpanishSites() -> [TorrentSearchSite] {
        let indices = Dictionary(uniqueKeysWithValues: spanishSites.enumerated().map { ($1, $0) })
        let enabled = searchPreferences.enabledSites

        return spanishSites.sorted { lhs, rhs in
            let lhsEnabled = enabled.contains(lhs)
            let rhsEnabled = enabled.contains(rhs)
            if lhsEnabled != rhsEnabled {
                return lhsEnabled
            }
            return indices[lhs, default: 0] < indices[rhs, default: 0]
        }
    }
}
private struct TransparentFormBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 13.0, iOS 16.0, *) {
            content
                .scrollContentBackground(.hidden)
                .background(Color.clear)
        } else {
            content
        }
    }
}

private extension View {
    func settingsRowAppearance() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 9, leading: 0, bottom: 9, trailing: 0))
            .listRowBackground(Color.clear)
    }
}
