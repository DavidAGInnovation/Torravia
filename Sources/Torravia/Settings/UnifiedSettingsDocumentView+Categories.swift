#if os(macOS)
import AppKit

extension UnifiedSettingsDocumentView {
    func buildGeneral(_ storage: NSMutableAttributedString) {
        heading("Seeding", to: storage)
        switchRow("Enable seeding after downloads complete", isOn: preferences.isSeedingEnabled, to: storage) { [weak preferences] in preferences?.isSeedingEnabled = $0 }
        heading("Notifications", to: storage)
        switchRow("Send notifications when downloads finish", isOn: preferences.areNotificationsEnabled, to: storage) { [weak preferences] in preferences?.areNotificationsEnabled = $0 }
        switchRow("Play a sound when downloads finish", isOn: preferences.isCompletionSoundEnabled, to: storage) { [weak preferences] in preferences?.isCompletionSoundEnabled = $0 }
        heading("Downloads", to: storage)
        append(downloadLocation.displayName, style: .secondary, to: storage)
        let buttons = blankLines(2, to: storage)
        place(button("Choose Location…") { [weak downloadLocation] in downloadLocation?.chooseLocation() }, at: buttons, x: 20, width: 150)
        let reset = button("Use System Default") { [weak self] in
            self?.downloadLocation.resetToSystemDownloads()
            self?.refreshAfterAction()
        }
        reset.isEnabled = downloadLocation.locationURL != nil
        place(reset, at: buttons, x: 368, width: 160)
    }

    func buildAutomation(_ storage: NSMutableAttributedString) {
        heading("Watched folder", to: storage)
        append(automation.watchedFolderDisplayName, style: .secondary, to: storage)
        let folderButtons = blankLines(2, to: storage)
        place(button("Choose Folder…") { [weak automation] in automation?.chooseWatchedFolder() }, at: folderButtons, x: 20, width: 140)
        let disable = button("Disable") { [weak self] in self?.automation.resetWatchedFolder(); self?.refreshAfterAction() }
        disable.isEnabled = automation.watchedFolderURL != nil
        place(disable, at: folderButtons, x: 428, width: 100)
        append("Torravia imports new .torrent files from this folder and keeps retrying files that are temporarily unavailable.", style: .caption, to: storage)

        heading(editingRSSRuleID == nil ? "Add RSS rule" : "Edit RSS rule", to: storage)
        let refreshRange = append("Feed URLs (comma-separated)", reserveControl: true, to: storage)
        let refresh = button("Refresh Now") { [weak downloadsVM] in downloadsVM?.refreshRSSFeeds() }
        refresh.isEnabled = !automation.rssFeedURLs.isEmpty
        place(refresh, at: refreshRange, x: 418, width: 110)
        let feedRange = blankLines(2, to: storage)
        place(textField("rssFeed", value: rssDraft?.feedURLs.joined(separator: ", ") ?? "",
                        placeholder: "https://example.com/feed.xml"), at: feedRange, x: 20, width: 508)
        fieldRow("Rule name (use one rule per series)", key: "rssName", value: rssDraft?.name ?? "", to: storage)
        fieldRow("Include title regex (comma-separated, optional)", key: "rssInclude", value: rssDraft?.include ?? "", to: storage)
        fieldRow("Exclude title regex (comma-separated, optional)", key: "rssExclude", value: rssDraft?.exclude ?? "", to: storage)
        fieldRow("Category folder (optional)", key: "rssCategory", value: rssDraft?.category ?? "", to: storage)
        checkboxRow("Require every include pattern", isOn: rssMatchAll, to: storage) { [weak self] in self?.rssMatchAll = $0 }
        fieldRow("Episode ranges (optional)", key: "rssEpisodes", value: rssDraft?.episodeFilter ?? "", to: storage)
        append("2x1-10; selects season 2, episodes 1–10. 2x5-; selects episode 5 onward and later seasons. Separate ranges with semicolons.", style: .caption, to: storage)
        checkboxRow("Skip episodes already matched by this rule", isOn: rssSmartEpisodes, to: storage) { [weak self] in self?.rssSmartEpisodes = $0 }
        checkboxRow("Allow REPACK / PROPER corrections", isOn: rssDownloadRepacks, to: storage) { [weak self] in self?.rssDownloadRepacks = $0 }
        append("Episode history is shared across this rule's feeds. Recognizes S02E05, 2x05, multi-episode releases, and date-based titles. With duplicate filtering on, titles without a recognized episode are skipped. History records queue imports, not completed downloads.", style: .caption, to: storage)
        fieldRow("Cooldown after a match (days, 0 disables)", key: "rssIgnoreDays", value: String(rssDraft?.ignoreDays ?? 0), to: storage)
        fieldRow("Maximum imports per poll (across all rule feeds)", key: "rssMaxItems", value: String(rssDraft?.maxItemsPerPoll ?? 50), to: storage)
        fieldRow("Tags (comma-separated)", key: "rssTags", value: rssDraft?.tags.joined(separator: ", ") ?? "", to: storage)
        checkboxRow("Start paused", isOn: rssStartPaused, to: storage) { [weak self] in self?.rssStartPaused = $0 }
        checkboxRow("Sequential", isOn: rssSequential, to: storage) { [weak self] in self?.rssSequential = $0 }
        pickerRow("Queue", titles: ["Normal", "Top", "Bottom"], selected: rssQueuePriority == 1 ? "Top" : rssQueuePriority == -1 ? "Bottom" : "Normal", to: storage) { [weak self] index in self?.rssQueuePriority = index == 1 ? 1 : index == 2 ? -1 : 0 }
        fieldRow("Sample title to test", key: "rssPreview", value: rssPreviewTitle, to: storage)
        if let rssPreviewResult { append(rssPreviewResult, style: .caption, to: storage) }
        if let rssRuleError { append(rssRuleError, style: .label, to: storage) }
        let formActions = blankLines(2, to: storage)
        place(button(editingRSSRuleID == nil ? "Add Rule" : "Save Rule") { [weak self] in self?.addRSSRule() }, at: formActions, x: 20, width: 120)
        place(button("Test Title") { [weak self] in self?.previewRSSRule() }, at: formActions, x: 150, width: 120)
        place(button("Cancel / Clear") { [weak self] in self?.resetRSSDraft() }, at: formActions, x: 280, width: 140)
        heading("Saved RSS rules", to: storage)
        append("Rules run from top to bottom; the first eligible match handles each item. Failed imports remain eligible for retry.", style: .caption, to: storage)
        if automation.rssRules.isEmpty {
            append("No rules configured. RSS items may contain magnet links or .torrent enclosures.", style: .caption, to: storage)
        }
        for (index, rule) in automation.rssRules.enumerated() {
            switchRow(rule.displayName, isOn: rule.enabled, to: storage) { [weak self] enabled in
                guard let self, var updated = self.automation.rssRules.first(where: { $0.id == rule.id }) else { return }
                updated.enabled = enabled
                self.automation.updateRSSRule(updated)
                self.refreshAfterAction()
            }
            append(rule.feedURLs.joined(separator: "\n"), style: .secondary, to: storage)
            append("Max \(rule.maxItemsPerPoll) per poll · \(rule.previouslyMatchedEpisodes.count) history entries", style: .caption, to: storage)
            let actions = blankLines(2, to: storage)
            place(button("Edit") { [weak self] in self?.resetRSSDraft(rule) }, at: actions, x: 20, width: 64)
            let up = button("↑") { [weak self] in self?.automation.moveRSSRule(id: rule.id, offset: -1); self?.refreshAfterAction() }
            up.setAccessibilityLabel("Move rule up"); up.isEnabled = index > 0
            place(up, at: actions, x: 92, width: 40)
            let down = button("↓") { [weak self] in self?.automation.moveRSSRule(id: rule.id, offset: 1); self?.refreshAfterAction() }
            down.setAccessibilityLabel("Move rule down"); down.isEnabled = index + 1 < automation.rssRules.count
            place(down, at: actions, x: 140, width: 40)
            place(button("Reset History") { [weak self] in self?.confirmRSSHistoryReset(id: rule.id) }, at: actions, x: 190, width: 140)
            place(button("Remove") { [weak self] in self?.automation.removeRSSRule(id: rule.id); self?.refreshAfterAction() }, at: actions, x: 438, width: 90)
        }

        heading("Remote control", to: storage)
        append(downloadsVM.alternativeWebUI?.directory.path ?? "Built-in browser interface", style: .secondary, to: storage)
        if let error = downloadsVM.alternativeWebUIError { append(error, style: .secondary, to: storage) }
        let interfaceControls = blankLines(2, to: storage)
        place(button("Choose Interface…") { [weak self] in
            guard let self else { return }
            AlternativeWebUIPanel.present(preferences: self.preferences, parent: self.window) { [weak self] in
                self?.downloadsVM.configureAlternativeWebUI()
                self?.refreshAfterAction()
            }
        }, at: interfaceControls, x: 20, width: 170)
        let builtIn = button("Use Built-in Interface") { [weak self] in
            self?.preferences.remoteWebUIBookmark = nil
            self?.downloadsVM.configureAlternativeWebUI()
            self?.refreshAfterAction()
        }
        builtIn.isEnabled = preferences.remoteWebUIBookmark != nil
        place(builtIn, at: interfaceControls, x: 340, width: 188)
        append("Alternative interfaces use the same access token and Torravia API. Choose only interface packages you trust.", style: .caption, to: storage)
        switchRow("Enable browser control", isOn: preferences.isRemoteControlEnabled, to: storage) { [weak preferences] in preferences?.isRemoteControlEnabled = $0 }
        switchRow("Allow connections from other devices", isOn: preferences.remoteControlAllowsLAN, to: storage) { [weak preferences] in preferences?.remoteControlAllowsLAN = $0 }
        stepperRow("Browser control port", value: preferences.remoteControlPort, range: 1024...65535, to: storage) { [weak preferences] in preferences?.remoteControlPort = $0 }
        switchRow("Use HTTPS", isOn: preferences.remoteControlUsesHTTPS, to: storage) { [weak self] enabled in
            self?.preferences.remoteControlUsesHTTPS = enabled
            self?.refreshAfterAction()
        }
        append(preferences.remoteControlTLSIdentity?.name ?? "No HTTPS certificate imported", style: .secondary, to: storage)
        let certificateControls = blankLines(2, to: storage)
        place(button("Import Certificate…") { [weak self] in
            guard let self else { return }
            RemoteCertificatePanel.present(preferences: self.preferences, parent: self.window) { [weak self] in
                self?.refreshAfterAction()
            }
        }, at: certificateControls, x: 20, width: 170)
        let forget = button("Forget Certificate") { [weak self] in
            self?.preferences.remoteControlTLSIdentity = nil
            self?.refreshAfterAction()
        }
        forget.isEnabled = preferences.remoteControlTLSIdentity != nil
        place(forget, at: certificateControls, x: 350, width: 178)
        if preferences.remoteControlUsesHTTPS {
            fieldRow("Certificate hostname (optional)", key: "remoteHostname", value: preferences.remoteControlHostname, to: storage)
            append("Import a .p12 or .pfx file containing your server certificate and private key. HTTPS encrypts browser and API traffic. The certificate must cover the hostname or IP address you open, and your browser must trust its issuer. A hostname is used when access from other devices is enabled.", style: .caption, to: storage)
        } else {
            append("HTTP sends the access token and traffic without encryption. Use a trusted local network or VPN, or enable HTTPS with a certificate.", style: .caption, to: storage)
        }
        append("Browser control requires a private access token and does not configure router port forwarding. Forgetting a certificate leaves its identity in Keychain.", style: .caption, to: storage)
        if let error = downloadsVM.remoteControlError { append(error, style: .secondary, to: storage) }
        if let url = downloadsVM.remoteControlURL {
            append(([url] + downloadsVM.remoteControlLANURLs).map(\.absoluteString).joined(separator: "\n"), style: .caption, to: storage)
            let controls = blankLines(2, to: storage)
            place(button("Open Browser") { [weak downloadsVM] in
                guard let url = downloadsVM?.remoteControlURL, let token = downloadsVM?.remoteControlToken else { return }
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.fragment = "token=\(token)"
                if let link = components?.url { NSWorkspace.shared.open(link) }
            }, at: controls, x: 20, width: 140)
            place(button("Copy Access Token") { [weak downloadsVM] in
                guard let token = downloadsVM?.remoteControlToken else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(token, forType: .string)
            }, at: controls, x: 340, width: 188)
            append("The access token changes when Torravia restarts. On another device, open a network address above and paste the token to sign in.", style: .caption, to: storage)
        } else if preferences.isRemoteControlEnabled && downloadsVM.remoteControlError == nil {
            append("Starting browser control…", style: .caption, to: storage)
        }

    }

    func fieldRow(_ label: String, key: String, value: String = "", secure: Bool = false, to storage: NSMutableAttributedString) {
        let range = append(label, reserveControl: true, to: storage)
        let field = textField(key, value: value, secure: secure)
        field.setAccessibilityLabel(label)
        place(field, at: range, x: 320, width: 208, height: 26)
    }

    func checkboxRow(_ title: String, isOn: Bool, to storage: NSMutableAttributedString, action: @escaping (Bool) -> Void) {
        let range = append(title, reserveControl: true, to: storage)
        place(checkbox(title, isOn: isOn, action: action), at: range, x: 500, width: 22, height: 22)
    }

    func buildTransfers(_ storage: NSMutableAttributedString) {
        heading("Scheduled bandwidth", to: storage)
        let scheduleRange = append(preferences.bandwidthSchedule.enabled ? "Schedule enabled" : "Schedule disabled", reserveControl: true, to: storage)
        place(button("Configure Schedule…") { [weak self] in
            guard let self else { return }
            PreferencesPanels.showBandwidthSchedule(self.preferences, parent: self.window)
        }, at: scheduleRange, x: 328, width: 200)
        append("Apply alternate upload and download limits on selected days and times.", style: .caption, to: storage)
        heading("Bandwidth & connections", to: storage)
        stepperRow("Listening port", value: preferences.listenPort, range: 49_152...65_535, to: storage) { [weak preferences] in preferences?.listenPort = $0 }
        stepperRow("Global peer limit", value: preferences.globalConnectionLimit, range: 50...1_000, step: 50, to: storage) { [weak preferences] in preferences?.globalConnectionLimit = $0 }
        stepperRow("Per-torrent peer limit", value: preferences.perTorrentConnectionLimit, range: 10...500, step: 10, to: storage) { [weak preferences] in preferences?.perTorrentConnectionLimit = $0 }
        stepperRow("Download limit", value: preferences.downloadLimitMBps, range: 0...1_000, step: 5, suffix: " MB/s", to: storage) { [weak preferences] in preferences?.downloadLimitMBps = $0 }
        stepperRow("Upload limit", value: preferences.uploadLimitMBps, range: 0...1_000, step: 5, suffix: " MB/s", to: storage) { [weak preferences] in preferences?.uploadLimitMBps = $0 }
        stepperRow("Global upload slots", value: preferences.globalUploadSlots, range: 1...200, to: storage) { [weak preferences] in preferences?.globalUploadSlots = $0 }
        stepperRow("Per-torrent upload slots", value: preferences.perTorrentUploadSlots, range: 1...50, to: storage) { [weak preferences] in preferences?.perTorrentUploadSlots = $0 }
        pickerRow("Disk I/O backend", titles: TorrentDiskIOBackend.allCases.map(\.title), selected: preferences.diskIOBackend.title, to: storage) { [weak preferences] index in preferences?.diskIOBackend = TorrentDiskIOBackend.allCases[index] }
        pickerRow("Read cache", titles: ["OS cache", "Direct I/O"], selected: preferences.diskIOReadMode == 2 ? "Direct I/O" : "OS cache", to: storage) { [weak preferences] index in preferences?.diskIOReadMode = index == 1 ? 2 : 0 }
        pickerRow("Write cache", titles: ["OS cache", "Direct I/O", "Write-through"], selected: preferences.diskIOWriteMode == 2 ? "Direct I/O" : preferences.diskIOWriteMode == 3 ? "Write-through" : "OS cache", to: storage) { [weak preferences] index in preferences?.diskIOWriteMode = index == 1 ? 2 : index == 2 ? 3 : 0 }
        switchRow("Preallocate files", isOn: preferences.preallocateFiles, to: storage) { [weak preferences] in preferences?.preallocateFiles = $0 }
        switchRow("Queue downloads", isOn: preferences.isQueueingEnabled, to: storage) { [weak self] value in self?.preferences.isQueueingEnabled = value; self?.refreshAfterAction() }
        if preferences.isQueueingEnabled {
            stepperRow("Maximum active downloads", value: preferences.maximumActiveDownloads, range: 1...50, to: storage) { [weak preferences] in preferences?.maximumActiveDownloads = $0 }
            stepperRow("Maximum active seeds", value: preferences.maximumActiveSeeds, range: 1...50, to: storage) { [weak preferences] in preferences?.maximumActiveSeeds = $0 }
            stepperRow("Maximum active torrents", value: preferences.maximumActiveTorrents, range: 1...100, to: storage) { [weak preferences] in preferences?.maximumActiveTorrents = $0 }
            switchRow("Don't count slow torrents", isOn: preferences.ignoreSlowTorrents, to: storage) { [weak preferences] in preferences?.ignoreSlowTorrents = $0 }
        }
        append("0 MB/s means unlimited. Upload slots control how many peers can receive data simultaneously. Changes apply immediately and persist across launches.", style: .caption, to: storage)
        append("Automatic selects a safe libtorrent backend; changing the backend applies the next time the native helper starts. Cache modes and adaptive disk queues apply immediately.", style: .caption, to: storage)
    }

    func buildNetwork(_ storage: NSMutableAttributedString) {
        heading("Network & privacy", to: storage)
        pickerRow("Peer transport", titles: TorrentTransportMode.allCases.map(\.title), selected: preferences.transportMode.title, to: storage) { [weak preferences] index in preferences?.transportMode = TorrentTransportMode.allCases[index] }
        pickerRow("Connection encryption", titles: TorrentEncryptionMode.allCases.map(\.title), selected: preferences.encryptionMode.title, to: storage) { [weak preferences] index in preferences?.encryptionMode = TorrentEncryptionMode.allCases[index] }
        fieldRow("Network interface (auto, all, en0, or utun4)", key: "networkInterface", value: preferences.networkInterface, to: storage)
        networkSwitch("Distributed Hash Table (DHT)", value: \SeedingPreferencesStore.isDHTEnabled, storage: storage)
        networkSwitch("Peer Exchange (PeX)", value: \SeedingPreferencesStore.isPeerExchangeEnabled, storage: storage)
        networkSwitch("Local Peer Discovery", value: \SeedingPreferencesStore.isLocalPeerDiscoveryEnabled, storage: storage)
        networkSwitch("Automatic UPnP port mapping", value: \SeedingPreferencesStore.isUPnPEnabled, storage: storage)
        networkSwitch("Automatic NAT-PMP port mapping", value: \SeedingPreferencesStore.isNATPMPEnabled, storage: storage)
        networkSwitch("Anonymous mode", value: \SeedingPreferencesStore.anonymousMode, storage: storage)
        networkSwitch("Protect against tracker SSRF", value: \SeedingPreferencesStore.ssrfMitigationEnabled, storage: storage)
        networkSwitch("Validate HTTPS tracker certificates", value: \SeedingPreferencesStore.validateHTTPSTrackers, storage: storage)
        networkSwitch("Block peers on privileged ports", value: \SeedingPreferencesStore.blockPrivilegedPeerPorts, storage: storage)
        networkSwitch("Allow multiple connections from one IP", value: \SeedingPreferencesStore.allowMultipleConnectionsPerIP, storage: storage)
        append("Additional trackers", style: .label, to: storage)
        let trackers = blankLines(3, to: storage)
        place(editor("additionalTrackers", value: preferences.additionalTrackerURLs), at: trackers, x: 20, width: 508, height: 82)
        append("One UDP, HTTP, or HTTPS tracker URL per line. These are added without removing the torrent's original announce list.", style: .caption, to: storage)
        switchRow("Enable I2P through a SAM bridge", isOn: preferences.isI2PEnabled, to: storage) { [weak self] value in self?.preferences.isI2PEnabled = value; self?.refreshAfterAction() }
        if preferences.isI2PEnabled {
            fieldRow("I2P SAM host", key: "i2pHost", value: preferences.i2pHost, to: storage)
            stepperRow("I2P SAM port", value: preferences.i2pPort, range: 1...65_535, to: storage) { [weak preferences] in preferences?.i2pPort = $0 }
            networkSwitch("Allow mixed I2P and public peers", value: \SeedingPreferencesStore.i2pMixedMode, storage: storage)
        }
        stepperRow("Outgoing port start", value: preferences.outgoingPortStart, range: 0...65_535, to: storage) { [weak preferences] in preferences?.outgoingPortStart = $0 }
        stepperRow("Outgoing port end", value: preferences.outgoingPortEnd, range: 0...65_535, to: storage) { [weak preferences] in preferences?.outgoingPortEnd = $0 }
        append("Leave the interface empty for automatic physical adapters. To route torrents through a VPN, enter its interface; invalid interfaces are rejected instead of silently using another route.", style: .caption, to: storage)

        heading("Proxy", to: storage)
        pickerRow("Proxy type", titles: TorrentProxyType.allCases.map(\.title), selected: preferences.proxyType.title, to: storage) { [weak self] index in self?.preferences.proxyType = TorrentProxyType.allCases[index]; self?.refreshAfterAction() }
        if preferences.proxyType != .none {
            fieldRow("Host", key: "proxyHost", value: preferences.proxyHost, to: storage)
            stepperRow("Port", value: preferences.proxyPort, range: 0...65_535, to: storage) { [weak preferences] in preferences?.proxyPort = $0 }
            fieldRow("Username (optional)", key: "proxyUsername", value: preferences.proxyUsername, to: storage)
            fieldRow("Password (stored in Keychain)", key: "proxyPassword", value: preferences.proxyPassword, secure: true, to: storage)
            networkSwitch("Proxy peer connections", value: \SeedingPreferencesStore.proxyPeerConnections, storage: storage)
            networkSwitch("Proxy tracker connections", value: \SeedingPreferencesStore.proxyTrackerConnections, storage: storage)
            networkSwitch("Resolve hostnames through proxy", value: \SeedingPreferencesStore.proxyHostnames, storage: storage)
        }

        heading("IP filter", to: storage)
        let blocked = blankLines(3, to: storage)
        place(editor("blockedIPRanges", value: preferences.blockedIPRanges), at: blocked, x: 20, width: 508, height: 82)
        append("One blocked IP, CIDR, or start-end range per line. Lines beginning with # are ignored. The filter also applies to trackers.", style: .caption, to: storage)
    }

    private func networkSwitch(_ title: String, value keyPath: ReferenceWritableKeyPath<SeedingPreferencesStore, Bool>, storage: NSMutableAttributedString) {
        switchRow(title, isOn: preferences[keyPath: keyPath], to: storage) { [weak preferences] value in preferences?[keyPath: keyPath] = value }
    }
}

#endif
