// Polling, discovery maintenance, and adaptive runtime tuning for Helper.

    void pollLoop() {
        auto lastNetworkStatus = std::chrono::steady_clock::time_point{};
        auto lastPeerStatus = std::chrono::steady_clock::time_point{};
        auto lastTorrentStatus = std::chrono::steady_clock::time_point{};
        auto lastDHTStateSave = std::chrono::steady_clock::now();
        auto lastResumeDataSave = std::chrono::steady_clock::now();
        auto lastDiscoveryMaintenance = std::chrono::steady_clock::time_point{};
        while (!shouldStop_.load(std::memory_order_relaxed)) {
            @autoreleasepool {
                const auto now = std::chrono::steady_clock::now();
                pollAlerts();
                if (lastDiscoveryMaintenance == std::chrono::steady_clock::time_point{}
                    || now - lastDiscoveryMaintenance >= std::chrono::seconds(5)) {
                    maintainPeerDiscovery(now);
                    lastDiscoveryMaintenance = now;
                }
                if (now - lastDHTStateSave >= std::chrono::seconds(30)) {
                    saveDHTState();
                    lastDHTStateSave = now;
                }
                // Resume data is durable state, not a live progress stream.
                // Saving every five minutes preserves restart recovery while
                // avoiding synchronous storage work during high-throughput
                // transfers. Pause/stop and shutdown still save immediately.
                if (now - lastResumeDataSave >= std::chrono::minutes(5)) {
                    requestResumeDataSaves();
                    lastResumeDataSave = now;
                }
                if (lastTorrentStatus == std::chrono::steady_clock::time_point{}
                    || now - lastTorrentStatus >= std::chrono::milliseconds(1'500)) {
                    session_.post_torrent_updates();
                    lastTorrentStatus = now;
                }

                if (lastPeerStatus == std::chrono::steady_clock::time_point{}
                    || now - lastPeerStatus >= std::chrono::seconds(2)) {
                    std::vector<std::string> subscriptions;
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        subscriptions.assign(peerDetailSubscriptions_.begin(),
                                             peerDetailSubscriptions_.end());
                    }
                    for (const auto &id : subscriptions) {
                        pollPeerDetails(id);
                    }
                    lastPeerStatus = now;
                }

                if (networkStatusDirty_
                    || lastNetworkStatus == std::chrono::steady_clock::time_point{}
                    || now - lastNetworkStatus >= std::chrono::seconds(2)) {
                    session_.post_session_stats();
                    sendEvent(networkStatusPayload());
                    networkStatusDirty_ = false;
                    lastNetworkStatus = now;
                }
            }
            // Wake as soon as libtorrent posts an alert, while retaining a
            // bounded timeout so discovery maintenance and shutdown checks
            // still run when the session is quiet.
            session_.wait_for_alert(lt::milliseconds(250));
        }
    }

    void updateDiscoveryTuning(bool aggressive) {
        if (aggressive == aggressiveDiscoveryEnabled_) {
            return;
        }

        lt::settings_pack tuning;
        TDApplyDiscoverySettings(tuning, aggressive);
        session_.apply_settings(std::move(tuning));
        aggressiveDiscoveryEnabled_ = aggressive;

        if (!aggressive) {
            // Trim recovery-sized disk budgets when discovery is healthy.
            std::lock_guard<std::mutex> lock(mutex_);
            for (auto &entry : torrents_) {
                entry.second.adaptiveDiskQueueBytes = std::min(
                    entry.second.adaptiveDiskQueueBytes, 512 * 1024 * 1024);
            }
        }
    }

    void refreshHashingThreadTuning() {
        bool hasSolidStateStorage = false;
        bool hasRotationalOrUnknownStorage = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (const auto &entry : torrents_) {
                if (!entry.second.handle.is_valid()) { continue; }
                if (entry.second.storageKind == TDStorageKind::solidState) {
                    hasSolidStateStorage = true;
                } else {
                    // Unknown media deliberately follows the HDD-safe path.
                    hasRotationalOrUnknownStorage = true;
                }
            }
        }

        // A single global setting must cover every active volume. Use the
        // HDD-safe profile whenever any torrent is rotational/unknown; use the
        // previous four-worker profile only when all known volumes are solid
        // state. The setting is used for full checks, not live piece hashing.
        const int desiredThreads = hasSolidStateStorage && !hasRotationalOrUnknownStorage
            ? 4 : 1;
        std::lock_guard<std::mutex> tuningLock(hashingTuningMutex_);
        if (desiredThreads == hashingThreads_) { return; }

        lt::settings_pack tuning;
        tuning.set_int(lt::settings_pack::hashing_threads, desiredThreads);
        session_.apply_settings(std::move(tuning));
        hashingThreads_ = desiredThreads;
    }

    void refreshDiskQueueProfile() {
        bool hasSolidStateStorage = false;
        bool hasRotationalOrUnknownStorage = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (const auto &entry : torrents_) {
                if (!entry.second.handle.is_valid()) { continue; }
                if (entry.second.storageKind == TDStorageKind::solidState) {
                    hasSolidStateStorage = true;
                } else {
                    hasRotationalOrUnknownStorage = true;
                }
            }
        }

        const int desiredBase = hasSolidStateStorage && !hasRotationalOrUnknownStorage
            ? 512 * 1024 * 1024
            : hasRotationalOrUnknownStorage ? 128 * 1024 * 1024
                                            : 256 * 1024 * 1024;
        if (desiredBase == baseDiskQueueBytes_) { return; }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (auto &entry : torrents_) {
                if (entry.second.diskLimitWarnings == 0) {
                    entry.second.adaptiveDiskQueueBytes = desiredBase;
                }
            }
        }
        baseDiskQueueBytes_ = desiredBase;
    }

    void updateAdaptiveTelemetry(TorrentRecord &record,
                                 const lt::torrent_status &status,
                                 std::chrono::steady_clock::time_point now) {
        const int diskQueueCeiling = aggressiveDiscoveryEnabled_
            ? 1'024 * 1024 * 1024 : 512 * 1024 * 1024;
        const double measuredRate = status.download_payload_rate > 0
            ? status.download_payload_rate : status.download_rate;
        if (record.lastTelemetrySample != std::chrono::steady_clock::time_point{}) {
            const double elapsed = std::chrono::duration<double>(
                now - record.lastTelemetrySample).count();
            if (elapsed > 0.0) {
                record.throughputEwma = record.throughputEwma == 0.0
                    ? measuredRate
                    : (record.throughputEwma * 0.8) + (measuredRate * 0.2);
            }
        }
        record.lastTelemetrySample = now;
        record.lastWantedDone = status.total_wanted_done;

        // A disk/send-buffer warning only arms an increase. Apply it after a
        // subsequent sample proves that the torrent is still making progress
        // faster than its pre-warning baseline; otherwise a saturated disk or
        // router would merely receive a larger queue without more throughput.
        const bool throughputImproved = record.adaptiveBaselineRate > 0.0
            && measuredRate >= record.adaptiveBaselineRate * 1.05;
        if (throughputImproved) {
            if (record.pendingDiskQueueIncrease) {
                record.adaptiveDiskQueueBytes = std::min(
                    record.adaptiveDiskQueueBytes * 2, diskQueueCeiling);
            }
            if (record.pendingSendBufferIncrease) {
                record.adaptiveSendBufferBytes = std::min(
                    record.adaptiveSendBufferBytes * 2, 8 * 1024 * 1024);
            }
            if (record.pendingDiskQueueIncrease || record.pendingSendBufferIncrease) {
                record.lastAdaptiveIncrease = now;
            }
            record.pendingDiskQueueIncrease = false;
            record.pendingSendBufferIncrease = false;
            record.adaptiveBaselineRate = 0.0;
            record.adaptiveWarningAt = {};
        } else if (record.adaptiveWarningAt != std::chrono::steady_clock::time_point{}
                   && now - record.adaptiveWarningAt >= std::chrono::seconds(90)) {
            // Never keep an unproductive increase armed forever. If disk or
            // upload-buffer pressure did not translate into more bytes delivered,
            // trim the per-torrent budgets so a slow volume cannot accumulate
            // an ever-growing backlog.
            if (record.pendingDiskQueueIncrease) {
                record.adaptiveDiskQueueBytes = std::max(
                    baseDiskQueueBytes_, record.adaptiveDiskQueueBytes * 3 / 4);
            }
            if (record.pendingSendBufferIncrease) {
                record.adaptiveSendBufferBytes = std::max(
                    2 * 1024 * 1024, record.adaptiveSendBufferBytes * 3 / 4);
            }
            record.pendingDiskQueueIncrease = false;
            record.pendingSendBufferIncrease = false;
            record.adaptiveBaselineRate = 0.0;
            record.adaptiveWarningAt = {};
        }

        // Warning-driven budgets decay after a quiet period. This prevents a
        // single bursty torrent from keeping a large queue forever while still
        // giving a healthy high-latency transfer time to prove it needs one.
        if (record.lastAdaptiveIncrease != std::chrono::steady_clock::time_point{}
            && now - record.lastAdaptiveIncrease >= std::chrono::seconds(90)) {
            record.adaptiveDiskQueueBytes = std::max(baseDiskQueueBytes_,
                record.adaptiveDiskQueueBytes / 2);
            record.adaptiveSendBufferBytes = std::max(2 * 1024 * 1024,
                record.adaptiveSendBufferBytes / 2);
            record.lastAdaptiveIncrease = now;
        }
    }

    void applyAdaptiveSessionSettings() {
        const int inboundRequestQueueFloor = aggressiveDiscoveryEnabled_
            ? TDAggressiveInboundRequestQueue : TDNormalInboundRequestQueue;
        const int diskQueueCeiling = aggressiveDiscoveryEnabled_
            ? 1'024 * 1024 * 1024 : 512 * 1024 * 1024;
        // libtorrent snapshots this default when a peer connects. Keep a
        // useful bounded window from the start instead of pretending a later
        // session update changes existing connections. Remote BEP 10 reqq
        // limits are still handled by the engine during the handshake.
        const int requestQueue = TDNormalOutboundRequestQueue;
        int inboundRequestQueue = inboundRequestQueueFloor;
        int diskQueue = baseDiskQueueBytes_;
        int sendBuffer = 2 * 1024 * 1024;
        int activePeers = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (const auto &entry : torrents_) {
                const TorrentRecord &record = entry.second;
                if (!record.handle.is_valid() || record.pauseRequested
                    || record.stopRequested) {
                    continue;
                }
                try {
                    activePeers = std::min(
                        10'000,
                        activePeers + std::clamp(record.handle.status().num_peers, 0, 10'000));
                } catch (...) {
                }
                diskQueue += std::max(0,
                    record.adaptiveDiskQueueBytes - baseDiskQueueBytes_);
                sendBuffer = std::max(sendBuffer, record.adaptiveSendBufferBytes);
            }
        }
        const std::uint64_t physicalMemory = TDPhysicalMemoryBytes();
        const int memoryInboundCeiling = TDMemoryBoundedQueueCeiling(
            inboundRequestQueueFloor,
            aggressiveDiscoveryEnabled_ ? 6'000 : TDNormalInboundRequestQueue,
            physicalMemory);
        const int peerInboundCeiling = std::min(
            aggressiveDiscoveryEnabled_ ? 6'000 : TDNormalInboundRequestQueue,
            inboundRequestQueueFloor + std::max(activePeers, 0) * 32);
        inboundRequestQueue = std::min({inboundRequestQueue,
                                        memoryInboundCeiling,
                                        peerInboundCeiling});

        diskQueue = std::min(diskQueue,
                             TDMemoryBoundedDiskCeiling(diskQueueCeiling,
                                                        physicalMemory));
        sendBuffer = std::min(sendBuffer, 8 * 1024 * 1024);
        const int peerRecvBuffer = TDMemoryBoundedPeerBuffer(activePeers, physicalMemory);
        const int socketBuffer = std::clamp(peerRecvBuffer / 2,
                                            1 * 1024 * 1024,
                                            4 * 1024 * 1024);
        if (requestQueue == adaptiveRequestQueue_
            && inboundRequestQueue == adaptiveInboundRequestQueue_
            && diskQueue == adaptiveDiskQueueBytes_
            && sendBuffer == adaptiveSendBufferBytes_
            && peerRecvBuffer == adaptivePeerRecvBufferBytes_
            && socketBuffer == adaptiveSocketBufferBytes_) {
            return;
        }

        lt::settings_pack tuning;
        tuning.set_int(lt::settings_pack::max_out_request_queue, requestQueue);
        tuning.set_int(lt::settings_pack::max_allowed_in_request_queue, inboundRequestQueue);
        tuning.set_int(lt::settings_pack::max_queued_disk_bytes, diskQueue);
        tuning.set_int(lt::settings_pack::send_buffer_watermark, sendBuffer);
        tuning.set_int(lt::settings_pack::max_peer_recv_buffer_size, peerRecvBuffer);
        tuning.set_int(lt::settings_pack::recv_socket_buffer_size, socketBuffer);
        tuning.set_int(lt::settings_pack::send_socket_buffer_size, socketBuffer);
        session_.apply_settings(std::move(tuning));
        adaptiveRequestQueue_ = requestQueue;
        adaptiveInboundRequestQueue_ = inboundRequestQueue;
        adaptiveDiskQueueBytes_ = diskQueue;
        adaptiveSendBufferBytes_ = sendBuffer;
        adaptivePeerRecvBufferBytes_ = peerRecvBuffer;
        adaptiveSocketBufferBytes_ = socketBuffer;
    }

    void rebalanceTorrentBudgets() {
        struct Candidate {
            std::string id;
            lt::torrent_handle handle;
            lt::torrent_status status;
            double score = 0.0;
        };

        std::vector<Candidate> candidates;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (auto &entry : torrents_) {
                TorrentRecord &record = entry.second;
                if (!record.handle.is_valid() || record.pauseRequested
                    || record.stopRequested) {
                    continue;
                }
                try {
                    const lt::torrent_status status = record.handle.status();
                    if (status.is_finished) { continue; }
                    const bool stalled = status.download_rate <= 0
                        && status.total_wanted_done < status.total_wanted;
                    const std::int64_t remainingBytes = std::max<std::int64_t>(
                        status.total_wanted - status.total_wanted_done, 0);
                    const double etaSeconds = status.download_rate > 0
                        ? static_cast<double>(remainingBytes)
                            / static_cast<double>(status.download_rate)
                        : 0.0;
                    // Favor torrents that can actually make progress, then
                    // rescue stalled torrents that still have candidates.
                    double score = record.throughputEwma / 1'000'000.0;
                    score += std::max(status.num_seeds, 0) * 4.0;
                    score += std::max(status.connect_candidates, 0) * 0.25;
                    score += stalled ? 100.0 : 0.0;
                    score += std::max(0.0, 1.0 - static_cast<double>(status.progress)) * 10.0;
                    if (record.peerConnectSuccessEwma > 0.5) { score += 5.0; }
                    // Preserve the user's queue order as a first-class input
                    // to the adaptive scheduler. Lower queue positions are
                    // intentionally weighted strongly, while the remaining
                    // terms still break ties between equally prioritized
                    // downloads.
                    const int queuePosition = static_cast<int>(status.queue_position);
                    if (queuePosition >= 0) {
                        score += 1'000.0 / static_cast<double>(queuePosition + 1);
                    }
                    // Expected useful work: a bounded bonus for sizeable
                    // remaining downloads and a completion-time bonus for
                    // torrents that can finish soon. Disk/rate-limiter
                    // contention is penalized so a saturated volume does not
                    // receive more sockets merely because it is busy.
                    score += std::min(
                        static_cast<double>(remainingBytes) / (1024.0 * 1024.0 * 1024.0),
                        20.0) * 0.5;
                    if (etaSeconds > 0.0) {
                        score += 20.0 / (1.0 + etaSeconds / 3'600.0);
                    }
                    score -= std::max(status.down_bandwidth_queue, 0) * 2.0;
                    score -= record.diskLimitWarnings * 5.0;
                    candidates.push_back(Candidate{entry.first, record.handle, status, score});
                } catch (...) {
                }
            }

            std::stable_sort(candidates.begin(), candidates.end(),
                             [](const Candidate &lhs, const Candidate &rhs) {
                                 return lhs.score > rhs.score;
                             });
            const int activeSlots = queueingEnabled_
                ? std::max(maximumActiveDownloads_, 1)
                : static_cast<int>(candidates.size());
            for (std::size_t rank = 0; rank < candidates.size(); ++rank) {
                auto it = torrents_.find(candidates[rank].id);
                if (it == torrents_.end()) { continue; }
                TorrentRecord &record = it->second;
                const bool getsActiveBudget = static_cast<int>(rank) < activeSlots;
                const int budget = getsActiveBudget
                    ? perTorrentConnectionLimit_
                    : std::max(8, perTorrentConnectionLimit_ / 4);
                if (record.appliedConnectionBudget != budget) {
                    record.handle.set_max_connections(budget);
                    record.appliedConnectionBudget = budget;
                }
                // Do not rewrite queue_position here. It is the user's
                // explicit ordering signal; the scheduler consumes it when
                // ranking and only adjusts connection budgets.
                record.schedulerRank = static_cast<int>(rank);
            }
        }
    }

    void maintainPeerDiscovery(std::chrono::steady_clock::time_point now) {
        std::vector<lt::torrent_handle> discoveryAnnounces;
        std::vector<lt::torrent_handle> dhtAnnounces;
        std::vector<lt::torrent_handle> trackerAnnounces;
        bool aggressiveDiscoveryNeeded = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (auto &entry : torrents_) {
                TorrentRecord &record = entry.second;
                if (!record.handle.is_valid() || record.pauseRequested || record.stopRequested) {
                    continue;
                }
                try {
                    const lt::torrent_status status = record.handle.status();
                    updateAdaptiveTelemetry(record, status, now);
                    applyAdaptiveTrackersIfNeeded(record, status);
                    if (status.is_finished) {
                        record.discoveryFailures = 0;
                        record.nextDiscoveryAttempt = {};
                        continue;
                    }

                    const int connectedPeers = std::max(status.num_peers, 0);
                    const int knownPeers = std::max(status.list_peers, connectedPeers);
                    const bool stalled = status.download_rate <= 0
                        && status.total_wanted_done < status.total_wanted;
                    // Keep discovery active while a torrent has only a small
                    // working set. The normal scheduler still controls the
                    // actual sockets; these announces only refresh candidate
                    // sources so a slow first peer does not hide a larger swarm.
                    const int targetConnections = std::clamp(
                        perTorrentConnectionLimit_ / 4, 8, 32);
                    const bool underConnected = connectedPeers < targetConnections
                        || (stalled && knownPeers > connectedPeers);

                    if (!underConnected) {
                        // Healthy transfers can rely on libtorrent's normal
                        // announce cadence and should not be interrupted.
                        record.discoveryFailures = 0;
                        record.nextDiscoveryAttempt = {};
                        continue;
                    }

                    // Only turn on the high-fanout DHT/tracker/peer-turnover
                    // profile while at least one active torrent actually needs
                    // more candidates. Healthy sessions keep the conservative
                    // baseline from TorrentSessionSettings.hpp.
                    aggressiveDiscoveryNeeded = true;

                    if (record.nextDiscoveryAttempt != std::chrono::steady_clock::time_point{}
                        && now < record.nextDiscoveryAttempt) {
                        continue;
                    }

                    // Keep DHT and local discovery fresh while a torrent is
                    // under-connected. Tracker refreshes are separately
                    // rate-limited below so a temporary outage cannot turn
                    // into a rapidly growing failure count.
                    discoveryAnnounces.push_back(record.handle);
                    dhtAnnounces.push_back(record.handle);
                    // Keep tracker-derived peer lists fresh for sparse or
                    // stalled swarms. The cooldown is per torrent so this
                    // cannot turn into a burst across the whole session.
                    const bool trackerRefreshDue =
                        record.nextTrackerAnnounce == std::chrono::steady_clock::time_point{}
                        || now >= record.nextTrackerAnnounce;
                    const bool trackerInCooldown = [&] {
                        for (const auto &tracker : record.trackerHealth) {
                            if (tracker.second.cooldownUntil == std::chrono::steady_clock::time_point{}
                                || now >= tracker.second.cooldownUntil) {
                                return false;
                            }
                        }
                        return !record.trackerHealth.empty();
                    }();
                    if (trackerRefreshDue && !trackerInCooldown
                        && (stalled || connectedPeers < 8)) {
                        trackerAnnounces.push_back(record.handle);
                        record.nextTrackerAnnounce = now + std::chrono::seconds(180);
                    }
                    record.discoveryFailures = std::min(record.discoveryFailures + 1, 5);

                    // Start promptly for peerless magnets, then back off to a
                    // bounded cadence without repeatedly hammering the DHT.
                    const int baseDelay = connectedPeers == 0 ? 30 : 60;
                    const int multiplier = 1 << std::max(record.discoveryFailures - 1, 0);
                    const int delay = std::min(baseDelay * multiplier, 300);
                    record.nextDiscoveryAttempt = now + std::chrono::seconds(delay);
                } catch (...) {
                    // The next maintenance cycle will retry if the handle becomes
                    // available again.
                }
            }
        }

        refreshHashingThreadTuning();
        refreshDiskQueueProfile();
        updateDiscoveryTuning(aggressiveDiscoveryNeeded);
        applyAdaptiveSessionSettings();
        rebalanceTorrentBudgets();

        // Perform network work after releasing the session lock.
        for (const auto &handle : dhtAnnounces) {
            try {
                handle.force_dht_announce();
            } catch (...) {
            }
        }
        for (const auto &handle : trackerAnnounces) {
            try {
                handle.force_reannounce(0, -1, lt::torrent_handle::high_priority);
            } catch (...) {
            }
        }
        if (localPeerDiscoveryEnabled_) {
            for (const auto &handle : discoveryAnnounces) {
                try { handle.force_lsd_announce(); } catch (...) { }
            }
        }
    }
