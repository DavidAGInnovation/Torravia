// Command decoding and runtime configuration for Helper.

    void readCommands() {
        std::string line;
        while (!shouldStop_.load(std::memory_order_relaxed) && std::getline(std::cin, line)) {
            if (line.empty()) { continue; }
            @autoreleasepool {
                NSData *data = [NSData dataWithBytes:line.data() length:line.size()];
                NSError *error = nil;
                NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                if (![command isKindOfClass:[NSDictionary class]]) {
                    sendError(nil, error.localizedDescription ?: @"Invalid command payload");
                    continue;
                }
                handleCommand(command);
            }
        }
    }

    void handleCommand(NSDictionary *command) {
        NSString *type = command[@"type"];
        NSString *identifier = command[@"id"];
        NSString *input = command[@"input"];
        NSString *destination = command[@"destination"];

        if (![type isKindOfClass:[NSString class]]) {
            sendError(nil, @"Missing command type");
            return;
        }

        const std::string typeValue = TDStdString(type);
        const std::string idValue = TDStdString(identifier);
        const std::string inputValue = TDStdString(input);
        const std::string destinationValue = TDStdString(destination);
        const std::string contentRoot = TDStdString(command[@"contentRoot"]);

        if (typeValue == "add") {
            addTorrent(idValue, inputValue, destinationValue, false, contentRoot, command[@"filePaths"], [command[@"seedOnly"] boolValue]);
        } else if (typeValue == "resume") {
            resumeTorrent(idValue, inputValue, destinationValue, contentRoot, command[@"filePaths"], [command[@"seedOnly"] boolValue]);
        } else if (typeValue == "pause") {
            pauseTorrent(idValue);
        } else if (typeValue == "cancel") {
            const bool deleteData = [command[@"destroyData"] boolValue];
            cancelTorrent(idValue, deleteData);
        } else if (typeValue == "stop") {
            stopSeeding(idValue);
        } else if (typeValue == "forceStart") {
            forceStartTorrent(idValue);
        } else if (typeValue == "queueTop") {
            setQueuePosition(idValue, true);
        } else if (typeValue == "queueBottom") {
            setQueuePosition(idValue, false);
        } else if (typeValue == "queueUp") {
            moveQueuePosition(idValue, true);
        } else if (typeValue == "queueDown") {
            moveQueuePosition(idValue, false);
        } else if (typeValue == "forceRecheck") {
            forceRecheckTorrent(idValue);
        } else if (typeValue == "setSequential") {
            setSequentialDownload(idValue, [command[@"enabled"] boolValue]);
        } else if (typeValue == "setFileSelection") {
            setFileSelection(idValue, command[@"selectedIndices"]);
        } else if (typeValue == "setFilePriority") {
            setFilePriority(idValue, [command[@"index"] intValue], [command[@"priority"] intValue]);
        } else if (typeValue == "setFirstLastPiecePriority") {
            setFirstLastPiecePriority(idValue, [command[@"enabled"] boolValue]);
        } else if (typeValue == "setTorrentLimits") {
            setTorrentLimits(idValue,
                             [command[@"downloadLimit"] intValue],
                             [command[@"uploadLimit"] intValue],
                             [command[@"maxUploads"] intValue]);
        } else if (typeValue == "setShareRatioPolicy") {
            setShareRatioPolicy(idValue,
                                [command[@"limit"] doubleValue],
                                [command[@"action"] intValue],
                                TDClampedInteger(command[@"seedingTimeLimit"], 0, 0, 5256000),
                                TDClampedInteger(command[@"inactiveSeedingTimeLimit"], 0, 0, 5256000),
                                [command[@"seedingSeconds"] longLongValue],
                                [command[@"inactiveSeconds"] longLongValue]);
        } else if (typeValue == "getDiscovery") {
            sendDiscovery(idValue);
        } else if (typeValue == "getPieceAvailability") {
            sendPieceAvailability(idValue);
        } else if (typeValue == "getPieceInspection") {
            sendPieceInspection(idValue);
        } else if (typeValue == "reannounce") {
            reannounceTorrent(idValue);
        } else if (typeValue == "addTracker") {
            addTracker(idValue, TDStdString(command[@"url"]), [command[@"tier"] intValue]);
        } else if (typeValue == "removeTracker") {
            removeTracker(idValue, TDStdString(command[@"url"]));
        } else if (typeValue == "addWebSeed") {
            addWebSeed(idValue, TDStdString(command[@"url"]));
        } else if (typeValue == "removeWebSeed") {
            removeWebSeed(idValue, TDStdString(command[@"url"]));
        } else if (typeValue == "addPeer") {
            addPeer(idValue, TDStdString(command[@"address"]));
        } else if (typeValue == "renameFile") {
            renameFile(idValue, [command[@"index"] intValue], TDStdString(command[@"path"]));
        } else if (typeValue == "banPeer") {
            banPeer(idValue, TDStdString(command[@"address"]));
        } else if (typeValue == "setPeerDetails") {
            setPeerDetailsEnabled(idValue, [command[@"enabled"] boolValue]);
        } else if (typeValue == "configure") {
            applyConfiguration(command);
        } else if (typeValue == "shutdown") {
            shouldStop_.store(true, std::memory_order_relaxed);
        } else {
            sendError(identifier, @"Unhandled command type");
        }
    }

    static int TDClampedInteger(id value, int fallback, int minimum, int maximum) {
        if (![value respondsToSelector:@selector(intValue)]) { return fallback; }
        return std::clamp([value intValue], minimum, maximum);
    }

    static std::string TDLowercase(std::string value) {
        std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
            return static_cast<char>(std::tolower(character));
        });
        return value;
    }

    static bool TDIsRetiredTracker(const std::string &url) {
        const std::string normalized = TDLowercase(TDTrim(url));
        // This UDP endpoint repeatedly fails announces in the active session.
        // Retire it from source magnets and fast-resume as well as defaults.
        if (normalized == "udp://explodie.org:6969/announce"
            || normalized == "udp://explodie.org:6969/announce/"
            || normalized == "udp://explodie.org:6969") { return true; }
        static const std::vector<std::string> retiredHosts = {
            "tracker.internetwarriors.net",
            "p4p.arenabg.ch",
            "tracker.openbittorrent.com",
            "www.torrent.eu.org",
            "retracker.lanta-net.ru",
            "exodus.desync.com",
            "tracker.tiny-vps.com",
            "tracker.coppersurfer.tk",
            "9.rarbg.to"
        };
        for (const auto &host : retiredHosts) {
            if (normalized.find(host) != std::string::npos) { return true; }
        }
        return false;
    }

    static std::vector<std::string> TDTrackerURLs(NSArray *values) {
        std::vector<std::string> result;
        std::unordered_set<std::string> seen;
        if (![values isKindOfClass:[NSArray class]]) { return result; }
        for (id value in values) {
            if (![value isKindOfClass:[NSString class]]) { continue; }
            const std::string tracker = TDTrim(TDStdString(value));
            if (!TDHasSupportedScheme(tracker, {"udp", "http", "https"})) { continue; }
            if (TDIsRetiredTracker(tracker)) { continue; }
            if (seen.insert(TDLowercase(tracker)).second) {
                result.push_back(tracker);
            }
        }
        return result;
    }

    // A download ID is stable across app launches, and older versions could
    // reuse that ID after the user selected a different magnet. Never apply
    // a fast-resume snapshot to a different info-hash: the snapshot contains
    // its own torrent_info, which otherwise wins over the new magnet's hash
    // and silently puts the session in the wrong swarm.
    static bool TDResumeMatchesSource(const lt::add_torrent_params &source,
                                      const lt::add_torrent_params &resume) {
        const lt::info_hash_t expected = source.ti
            ? source.ti->info_hashes() : source.info_hashes;
        const lt::info_hash_t actual = resume.ti
            ? resume.ti->info_hashes() : resume.info_hashes;
        if (!expected.has_v1() && !expected.has_v2()) {
            return true;
        }
        if (expected.has_v1()
            && (!actual.has_v1() || expected.v1 != actual.v1)) {
            return false;
        }
        if (expected.has_v2()
            && (!actual.has_v2() || expected.v2 != actual.v2)) {
            return false;
        }
        return true;
    }

    void appendConfiguredTrackers(lt::add_torrent_params &params) const {
        std::vector<std::string> retainedTrackers;
        std::vector<int> retainedTiers;
        retainedTrackers.reserve(params.trackers.size());
        retainedTiers.reserve(params.trackers.size());
        for (std::size_t index = 0; index < params.trackers.size(); ++index) {
            const std::string &tracker = params.trackers[index];
            if (TDIsRetiredTracker(tracker)) { continue; }
            retainedTrackers.push_back(tracker);
            retainedTiers.push_back(index < params.tracker_tiers.size()
                                    ? params.tracker_tiers[index] : 0);
        }
        params.trackers = std::move(retainedTrackers);
        params.tracker_tiers = std::move(retainedTiers);
        std::unordered_set<std::string> seen;
        for (const auto &tracker : params.trackers) {
            seen.insert(TDLowercase(tracker));
        }
        int tier = params.tracker_tiers.empty() ? 0 : *std::max_element(
            params.tracker_tiers.begin(), params.tracker_tiers.end());

        // A magnet has no metadata yet, so its private/public flag is
        // unknown. Do not inject public trackers until metadata is available;
        // private torrents must remain on their signed announce list.
        if (!params.ti || params.ti->priv()) {
            return;
        }

        for (const auto &tracker : additionalTrackerURLs_) {
            if (!seen.insert(TDLowercase(tracker)).second) { continue; }
            params.trackers.push_back(tracker);
            params.tracker_tiers.push_back(tier + 1);
        }

        // For metadata-bearing public torrents, add curated candidates at
        // creation time. Hash-only magnets are intentionally deferred until
        // metadata arrives so a private torrent can never receive them.
        if (params.trackers.empty() && !adaptiveTrackerURLs_.empty()) {
            for (const auto &tracker : adaptiveTrackerURLs_) {
                if (!seen.insert(TDLowercase(tracker)).second) { continue; }
                params.trackers.push_back(tracker);
                params.tracker_tiers.push_back(tier + 1);
            }
        }
    }

    void applyAdaptiveTrackersIfNeeded(TorrentRecord &record,
                                       const lt::torrent_status &status) {
        if (status.is_finished
            || bool(status.flags & lt::torrent_flags::paused)
            || status.total_wanted_done >= status.total_wanted
            || status.download_rate >= 1'000'000
            || record.adaptiveTrackersApplied
            || !record.handle.is_valid()) {
            return;
        }

        const auto info = record.handle.torrent_file();
        if (!info) {
            // Metadata is still being fetched. In particular, do not assume
            // that a hash-only magnet is public until this is known.
            return;
        }
        if (info->priv()) {
            record.adaptiveTrackersApplied = true;
            return;
        }

        std::vector<std::string> candidateURLs = additionalTrackerURLs_;
        candidateURLs.insert(candidateURLs.end(), adaptiveTrackerURLs_.begin(),
                             adaptiveTrackerURLs_.end());
        std::stable_sort(candidateURLs.begin(), candidateURLs.end(), [&](const std::string &lhs,
                                                                          const std::string &rhs) {
            const auto score = [&](const std::string &url) {
                const auto it = record.trackerHealth.find(TDLowercase(url));
                if (it == record.trackerHealth.end()) { return 0.0; }
                const TorrentRecord::TrackerHealth &health = it->second;
                return static_cast<double>(health.successes * 100
                                           + health.lastPeerCount * 10
                                           - health.consecutiveFailures * 25);
            };
            return score(lhs) > score(rhs);
        });

        auto trackers = record.handle.trackers();
        std::unordered_set<std::string> seen;
        trackers.erase(std::remove_if(trackers.begin(), trackers.end(), [&](const lt::announce_entry &tracker) {
            if (TDIsRetiredTracker(tracker.url)) { return true; }
            return !seen.insert(TDLowercase(tracker.url)).second;
        }), trackers.end());

        int tier = trackers.empty() ? 0 : trackers.back().tier;
        bool changed = false;
        const auto now = std::chrono::steady_clock::now();
        for (std::size_t index = 0; index < candidateURLs.size(); ++index) {
            const auto &tracker = candidateURLs[index];
            if (!seen.insert(TDLowercase(tracker)).second) { continue; }
            const auto health = record.trackerHealth.find(TDLowercase(tracker));
            if (health != record.trackerHealth.end()
                && health->second.cooldownUntil != std::chrono::steady_clock::time_point{}
                && now < health->second.cooldownUntil) {
                // A tracker that is already failing will be retried by
                // libtorrent's own announce backoff. Do not re-add it to the
                // adaptive tier while its wrapper cooldown is active.
                continue;
            }
            lt::announce_entry entry(tracker);
            // Lower tiers are preferred by libtorrent. Keep the scored order
            // instead of putting every candidate into one indistinguishable
            // tier, so proven trackers are attempted before cold/failing ones.
            entry.tier = static_cast<std::uint8_t>(std::min(
                tier + 1 + static_cast<int>(index), 255));
            trackers.push_back(std::move(entry));
            changed = true;
        }

        record.adaptiveTrackersApplied = true;
        if (!changed) { return; }
        record.handle.replace_trackers(std::move(trackers));
        try { record.handle.force_reannounce(0, -1, lt::torrent_handle::high_priority); } catch (...) { }
    }

    void applyConfiguration(NSDictionary *command) {
        const int listenPort = TDClampedInteger(command[@"listenPort"], 55'000, 49'152, 65'535);
        const int globalConnections = TDClampedInteger(
            command[@"globalConnectionLimit"], 500, 50, 1'000);
        const int perTorrentConnections = TDClampedInteger(
            command[@"perTorrentConnectionLimit"], 100, 10, 500);
        const int downloadLimit = TDClampedInteger(
            command[@"downloadLimit"], 0, 0, 1'000'000'000);
        const int uploadLimit = TDClampedInteger(
            command[@"uploadLimit"], 0, 0, 1'000'000'000);
        const bool queueingEnabled = [command[@"queueingEnabled"] boolValue];
        const int maximumActiveDownloads = TDClampedInteger(
            command[@"maximumActiveDownloads"], 3, 1, 50);
        const int maximumActiveSeeds = TDClampedInteger(
            command[@"maximumActiveSeeds"], 3, 1, 50);
        const int maximumActiveTorrents = TDClampedInteger(
            command[@"maximumActiveTorrents"], 5, 1, 100);
        const bool ignoreSlowTorrents = [command[@"ignoreSlowTorrents"] boolValue];
        const int globalUploadSlots = TDClampedInteger(
            command[@"globalUploadSlots"], 20, 1, 200);
        const int perTorrentUploadSlots = TDClampedInteger(
            command[@"perTorrentUploadSlots"], 4, 1, 50);
        const std::string networkInterface = TDTrim(TDStdString(command[@"networkInterface"]));
        const std::string transportMode = TDStdString(command[@"transportMode"]);
        const std::string encryptionMode = TDStdString(command[@"encryptionMode"]);
        const int diskIOReadMode = TDClampedInteger(command[@"diskIOReadMode"], 0, 0, 2);
        const int diskIOWriteMode = TDClampedInteger(command[@"diskIOWriteMode"], 0, 0, 3);
        const bool preallocateFiles = [command[@"preallocateFiles"] boolValue];
        const int outgoingPortStart = TDClampedInteger(command[@"outgoingPortStart"], 0, 0, 65'535);
        const int outgoingPortEnd = TDClampedInteger(command[@"outgoingPortEnd"], 0, 0, 65'535);
        const bool dhtEnabled = [command[@"dhtEnabled"] boolValue];
        const bool peerExchangeEnabled = [command[@"peerExchangeEnabled"] boolValue];
        const bool localPeerDiscoveryEnabled = [command[@"localPeerDiscoveryEnabled"] boolValue];
        const bool upnpEnabled = [command[@"upnpEnabled"] boolValue];
        const bool natpmpEnabled = [command[@"natpmpEnabled"] boolValue];
        const std::string proxyType = TDStdString(command[@"proxyType"]);
        const std::string proxyHost = TDTrim(TDStdString(command[@"proxyHost"]));
        const int proxyPort = TDClampedInteger(command[@"proxyPort"], 0, 0, 65'535);
        const std::string proxyUsername = TDStdString(command[@"proxyUsername"]);
        const std::string proxyPassword = TDStdString(command[@"proxyPassword"]);
        const bool proxyPeerConnections = [command[@"proxyPeerConnections"] boolValue];
        const bool proxyHostnames = [command[@"proxyHostnames"] boolValue];
        const bool proxyTrackerConnections = [command[@"proxyTrackerConnections"] boolValue];
        const bool anonymousMode = [command[@"anonymousMode"] boolValue];
        const bool ssrfMitigationEnabled = [command[@"ssrfMitigationEnabled"] boolValue];
        const bool validateHTTPSTrackers = [command[@"validateHTTPSTrackers"] boolValue];
        const bool blockPrivilegedPeerPorts = [command[@"blockPrivilegedPeerPorts"] boolValue];
        const bool allowMultipleConnectionsPerIP = [command[@"allowMultipleConnectionsPerIP"] boolValue];
        const bool i2pEnabled = [command[@"i2pEnabled"] boolValue];
        const std::string i2pHost = TDTrim(TDStdString(command[@"i2pHost"]));
        const int i2pPort = TDClampedInteger(command[@"i2pPort"], 7'656, 1, 65'535);
        const bool i2pMixedMode = [command[@"i2pMixedMode"] boolValue];
        const std::vector<std::string> additionalTrackerURLs = TDTrackerURLs(command[@"additionalTrackerURLs"]);
        const std::vector<std::string> adaptiveTrackerURLs = TDTrackerURLs(command[@"adaptiveTrackerURLs"]);

        const bool hasExplicitNetworkInterface = !networkInterface.empty();
        const bool useAllNetworkInterfaces = hasExplicitNetworkInterface
            && TDLowercase(TDTrim(networkInterface)) == "all";
        if (hasExplicitNetworkInterface
            && !TDNetworkInterfaceIsUsable(networkInterface)) {
            sendError(nil, @"The selected network interface is unavailable. Use a live interface name (for example en0 or utun4), an IP address, or 'all'.");
            return;
        }

        preallocateFiles_ = preallocateFiles;

        lt::settings_pack pack;
        // When no adapter is selected, keep the automatic path on active
        // physical adapters. VPN/tunnel adapters can advertise link-local
        // addresses that accept sockets but cannot reach public trackers or
        // peers, so they are excluded by the address helpers.
        std::string automaticListenInterfaces;
        if (!hasExplicitNetworkInterface) {
            const auto appendInterface = [&](const std::string &address,
                                             bool ipv6) {
                if (!automaticListenInterfaces.empty()) {
                    automaticListenInterfaces += ",";
                }
                automaticListenInterfaces += ipv6 ? "[" + address + "]:" + std::to_string(listenPort)
                                                  : address + ":" + std::to_string(listenPort);
            };
            for (const auto &address : TDActiveIPv4Addresses()) {
                appendInterface(address, false);
            }
            for (const auto &address : TDActiveIPv6Addresses()) {
                // Keep IPv6 listeners available for incoming peers, but let
                // the OS choose the best outbound route. Some networks
                // advertise global/ULA IPv6 addresses without usable routes
                // to UDP trackers, which would otherwise create retry churn.
                appendInterface(address, true);
            }
        }
        const std::string listenInterfaces = useAllNetworkInterfaces
            ? "0.0.0.0:" + std::to_string(listenPort)
                + ",[::]:" + std::to_string(listenPort)
            : hasExplicitNetworkInterface
            ? networkInterface + ":" + std::to_string(listenPort)
            : automaticListenInterfaces.empty()
                ? "0.0.0.0:" + std::to_string(listenPort)
                : automaticListenInterfaces;
        // An empty outgoing_interfaces value deliberately leaves outbound
        // socket selection to the OS. The previous automatic path bound only
        // to physical IPv4 addresses, which excluded otherwise usable IPv6
        // and VPN routes from peer/tracker connections. Explicit bindings
        // remain strict, while `all` means all routes for both families.
        const std::string outgoingInterfaces = useAllNetworkInterfaces
            ? ""
            : hasExplicitNetworkInterface
            ? networkInterface
            : "";

        if (hasExplicitNetworkInterface) {
            networkInterfaceWarning_.clear();
        } else {
            const auto virtualAdapters = TDActiveVirtualAdapterNames();
            if (!virtualAdapters.empty()) {
                std::string warning =
                    "Automatic listening is bound to physical adapters; outbound connections still follow the OS route. Active VPN/tunnel adapters are not used for incoming listening (";
                for (std::size_t index = 0; index < virtualAdapters.size(); ++index) {
                    if (index > 0) { warning += ", "; }
                    warning += virtualAdapters[index];
                }
                warning += "). Enter an interface name explicitly if inbound VPN/tunnel listening is required.";
                if (warning != networkInterfaceWarning_) {
                    sendEvent(@{@"type": @"warning", @"message": TDNSString(warning)});
                    networkInterfaceWarning_ = warning;
                }
            } else {
                networkInterfaceWarning_.clear();
            }
        }
        pack.set_str(lt::settings_pack::listen_interfaces, listenInterfaces);
        // Keep the fallback enabled when settings are reapplied at runtime;
        // otherwise a port collision after a network/interface change could
        // leave the session without an inbound socket.
        pack.set_bool(lt::settings_pack::listen_system_port_fallback, true);
        pack.set_str(lt::settings_pack::outgoing_interfaces, outgoingInterfaces);
        pack.set_int(lt::settings_pack::connections_limit, globalConnections);
        pack.set_int(lt::settings_pack::download_rate_limit, downloadLimit);
        pack.set_int(lt::settings_pack::upload_rate_limit, uploadLimit);
        pack.set_int(lt::settings_pack::unchoke_slots_limit, globalUploadSlots);
        pack.set_int(lt::settings_pack::disk_io_read_mode, diskIOReadMode);
        pack.set_int(lt::settings_pack::disk_io_write_mode, diskIOWriteMode);
        pack.set_int(lt::settings_pack::active_downloads,
                     queueingEnabled ? maximumActiveDownloads : -1);
        pack.set_int(lt::settings_pack::active_seeds,
                     queueingEnabled ? maximumActiveSeeds : -1);
        pack.set_int(lt::settings_pack::active_limit,
                     queueingEnabled ? maximumActiveTorrents : -1);
        pack.set_bool(lt::settings_pack::dont_count_slow_torrents,
                      queueingEnabled && ignoreSlowTorrents);
        pack.set_int(lt::settings_pack::inactive_down_rate, 2 * 1024);
        pack.set_int(lt::settings_pack::inactive_up_rate, 2 * 1024);
        pack.set_int(lt::settings_pack::auto_manage_startup, 60);
        const bool tcpEnabled = transportMode != "utp";
        const bool utpEnabled = transportMode != "tcp";
        pack.set_bool(lt::settings_pack::enable_incoming_tcp, tcpEnabled);
        pack.set_bool(lt::settings_pack::enable_outgoing_tcp, tcpEnabled);
        pack.set_bool(lt::settings_pack::enable_incoming_utp, utpEnabled);
        pack.set_bool(lt::settings_pack::enable_outgoing_utp, utpEnabled);
        pack.set_bool(lt::settings_pack::enable_dht, dhtEnabled);
        pack.set_bool(lt::settings_pack::enable_lsd, localPeerDiscoveryEnabled);
        pack.set_bool(lt::settings_pack::enable_upnp, upnpEnabled);
        pack.set_bool(lt::settings_pack::enable_natpmp, natpmpEnabled);
        const int encryptionPolicy = encryptionMode == "required"
            ? lt::settings_pack::pe_forced
            : encryptionMode == "disabled" ? lt::settings_pack::pe_disabled : lt::settings_pack::pe_enabled;
        pack.set_int(lt::settings_pack::in_enc_policy, encryptionPolicy);
        pack.set_int(lt::settings_pack::out_enc_policy, encryptionPolicy);
        pack.set_int(lt::settings_pack::allowed_enc_level, lt::settings_pack::pe_both);
        pack.set_bool(lt::settings_pack::prefer_rc4, false);
        if (outgoingPortStart > 0 && outgoingPortEnd >= outgoingPortStart) {
            pack.set_int(lt::settings_pack::outgoing_port, outgoingPortStart);
            pack.set_int(lt::settings_pack::num_outgoing_ports, outgoingPortEnd - outgoingPortStart + 1);
        } else {
            pack.set_int(lt::settings_pack::outgoing_port, 0);
            pack.set_int(lt::settings_pack::num_outgoing_ports, 0);
        }
        int nativeProxyType = lt::settings_pack::none;
        if (!proxyHost.empty() && proxyPort > 0) {
            if (proxyType == "socks4") nativeProxyType = lt::settings_pack::socks4;
            if (proxyType == "socks5") nativeProxyType = proxyUsername.empty()
                ? lt::settings_pack::socks5 : lt::settings_pack::socks5_pw;
            if (proxyType == "http") nativeProxyType = proxyUsername.empty()
                ? lt::settings_pack::http : lt::settings_pack::http_pw;
        }
        pack.set_int(lt::settings_pack::proxy_type, nativeProxyType);
        pack.set_str(lt::settings_pack::proxy_hostname, proxyHost);
        pack.set_int(lt::settings_pack::proxy_port, proxyPort);
        pack.set_str(lt::settings_pack::proxy_username, proxyUsername);
        pack.set_str(lt::settings_pack::proxy_password, proxyPassword);
        pack.set_bool(lt::settings_pack::proxy_peer_connections, proxyPeerConnections);
        pack.set_bool(lt::settings_pack::proxy_tracker_connections,
                      nativeProxyType != lt::settings_pack::none && proxyTrackerConnections);
        pack.set_bool(lt::settings_pack::proxy_hostnames, proxyHostnames);
        pack.set_bool(lt::settings_pack::apply_ip_filter_to_trackers, true);
        pack.set_bool(lt::settings_pack::anonymous_mode, anonymousMode);
        pack.set_bool(lt::settings_pack::ssrf_mitigation, ssrfMitigationEnabled);
        pack.set_bool(lt::settings_pack::validate_https_trackers, validateHTTPSTrackers);
        pack.set_bool(lt::settings_pack::no_connect_privileged_ports, blockPrivilegedPeerPorts);
        pack.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, allowMultipleConnectionsPerIP);
        pack.set_str(lt::settings_pack::i2p_hostname, i2pEnabled ? i2pHost : "");
        pack.set_int(lt::settings_pack::i2p_port, i2pPort);
        pack.set_bool(lt::settings_pack::allow_i2p_mixed, i2pMixedMode);
        session_.apply_settings(std::move(pack));

        lt::ip_filter ipFilter;
        NSArray *blockedRanges = command[@"blockedIPRanges"];
        if ([blockedRanges isKindOfClass:[NSArray class]]) {
            for (id entry in blockedRanges) {
                if (![entry isKindOfClass:[NSString class]]) { continue; }
                lt::address first;
                lt::address last;
                if (TDParseBlockedRange(TDStdString(entry), first, last)) {
                    ipFilter.add_rule(first, last, lt::ip_filter::blocked);
                }
            }
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (const auto &addressText : bannedPeers_) {
                lt::address address;
                if (TDParseAddress(addressText, address)) {
                    ipFilter.add_rule(address, address, lt::ip_filter::blocked);
                }
            }
        }
        session_.set_ip_filter(std::move(ipFilter));

        {
            std::lock_guard<std::mutex> lock(mutex_);
            connectionLimit_ = globalConnections;
            perTorrentConnectionLimit_ = perTorrentConnections;
            queueingEnabled_ = queueingEnabled;
            maximumActiveDownloads_ = maximumActiveDownloads;
            maximumActiveSeeds_ = maximumActiveSeeds;
            maximumActiveTorrents_ = maximumActiveTorrents;
            ignoreSlowTorrents_ = ignoreSlowTorrents;
            globalUploadSlots_ = globalUploadSlots;
            perTorrentUploadSlots_ = perTorrentUploadSlots;
            dhtEnabled_ = dhtEnabled;
            peerExchangeEnabled_ = peerExchangeEnabled;
            localPeerDiscoveryEnabled_ = localPeerDiscoveryEnabled;
            additionalTrackerURLs_ = additionalTrackerURLs;
            const bool adaptiveTrackersChanged = adaptiveTrackerURLs_ != adaptiveTrackerURLs;
            adaptiveTrackerURLs_ = adaptiveTrackerURLs;
            for (auto &entry : torrents_) {
                TorrentRecord &record = entry.second;
                if (!record.handle.is_valid()) { continue; }
                if (adaptiveTrackersChanged) { record.adaptiveTrackersApplied = false; }
                record.handle.set_max_connections(perTorrentConnections);
                record.handle.set_max_uploads(perTorrentUploadSlots);
                auto trackers = record.handle.trackers();
                std::unordered_set<std::string> seen;
                trackers.erase(std::remove_if(trackers.begin(), trackers.end(), [&](const lt::announce_entry &tracker) {
                    if (TDIsRetiredTracker(tracker.url)) { return true; }
                    return !seen.insert(TDLowercase(tracker.url)).second;
                }), trackers.end());
                int tier = trackers.empty() ? 0 : trackers.back().tier;
                for (const auto &tracker : additionalTrackerURLs_) {
                    if (!seen.insert(TDLowercase(tracker)).second) { continue; }
                    lt::announce_entry entry(tracker);
                    entry.tier = tier + 1;
                    trackers.push_back(std::move(entry));
                }
                const bool trackersChanged = trackers.size() != record.handle.trackers().size();
                record.handle.replace_trackers(std::move(trackers));
                if (trackersChanged && !additionalTrackerURLs_.empty()) {
                    try { record.handle.force_reannounce(0, -1, lt::torrent_handle::high_priority); } catch (...) { }
                }
                if (dhtEnabled) {
                    try { record.handle.force_dht_announce(); } catch (...) { }
                }
                if (localPeerDiscoveryEnabled) {
                    try { record.handle.force_lsd_announce(); } catch (...) { }
                }
                if (dhtEnabled) record.handle.unset_flags(lt::torrent_flags::disable_dht);
                else record.handle.set_flags(lt::torrent_flags::disable_dht);
                if (peerExchangeEnabled) record.handle.unset_flags(lt::torrent_flags::disable_pex);
                else record.handle.set_flags(lt::torrent_flags::disable_pex);
                if (localPeerDiscoveryEnabled) record.handle.unset_flags(lt::torrent_flags::disable_lsd);
                else record.handle.set_flags(lt::torrent_flags::disable_lsd);
                if (record.pauseRequested || record.stopRequested) { continue; }
                if (queueingEnabled && !record.seedOnly) {
                    record.handle.set_flags(lt::torrent_flags::auto_managed);
                    record.handle.resume();
                } else {
                    record.handle.unset_flags(lt::torrent_flags::auto_managed);
                    record.handle.resume();
                }
            }
        }
        upnpStatus_ = "pending";
        natpmpStatus_ = "pending";
        networkStatusDirty_ = true;
        // The session was created paused so all interface, proxy, limiter, and
        // discovery settings are in place before any torrent can connect.
        if (!sessionConfigurationApplied_) {
            session_.resume();
            sessionConfigurationApplied_ = true;
        }
    }
