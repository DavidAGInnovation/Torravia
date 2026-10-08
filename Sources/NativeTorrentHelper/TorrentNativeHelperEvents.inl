// Network, torrent-status, and JSON event emission for Helper.

    void reannounceAfterListenRecovery() {
        std::vector<lt::torrent_handle> handles;
        bool dhtEnabled = false;
        bool lsdEnabled = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            dhtEnabled = dhtEnabled_;
            lsdEnabled = localPeerDiscoveryEnabled_;
            handles.reserve(torrents_.size());
            for (const auto &entry : torrents_) {
                if (entry.second.handle.is_valid()
                    && !entry.second.pauseRequested
                    && !entry.second.stopRequested) {
                    handles.push_back(entry.second.handle);
                }
            }
        }

        for (const auto &handle : handles) {
            try {
                handle.force_reannounce(0, -1, lt::torrent_handle::high_priority);
                if (dhtEnabled) { handle.force_dht_announce(); }
                if (lsdEnabled) { handle.force_lsd_announce(); }
            } catch (...) {
                // The regular maintenance loop will retry discovery if a
                // handle is no longer valid during the port transition.
            }
        }
    }

    NSDictionary *networkStatusPayload() const {
        const bool listening = session_.is_listening();
        const std::string effectiveListenState = listening ? "listening" : listenState_;
        NSMutableDictionary *payload = [@{
            @"type": @"networkStatus",
            @"listenPort": @(listening ? session_.listen_port() : listenPort_),
            @"isListening": @(listening),
            @"listenState": TDNSString(effectiveListenState),
            @"connectionLimit": @(connectionLimit_),
            @"engineVersion": TDNSString(std::string("libtorrent ") + lt::version()),
            @"upnpStatus": TDNSString(upnpStatus_),
            @"natpmpStatus": TDNSString(natpmpStatus_),
            @"trackerStatus": TDNSString(trackerStatus_),
            @"trackerAnnounces": @(trackerAnnounces_),
            @"trackerReplies": @(trackerReplies_),
            @"trackerErrors": @(trackerErrors_),
            @"alertsDropped": @(alertsDropped_),
            @"dhtStatus": TDNSString(session_.is_dht_running() ? dhtStatus_ : "disabled"),
            @"dhtReplies": @(dhtReplies_),
            @"dhtNodes": @(dhtNodes_)
        } mutableCopy];
        if (!lastTrackerURL_.empty()) {
            payload[@"lastTrackerURL"] = TDNSString(lastTrackerURL_);
        }
        if (!lastTrackerError_.empty()) {
            payload[@"lastTrackerError"] = TDNSString(lastTrackerError_);
        }
        return payload;
    }

    void processTorrentStatus(const lt::torrent_status &status) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = std::find_if(torrents_.begin(), torrents_.end(), [&](const auto &entry) {
            return entry.second.handle == status.handle;
        });
        if (it == torrents_.end()) { return; }

        TorrentRecord &record = it->second;
        if (!record.handle.is_valid() || record.layoutFailed) { return; }

        if (status.errc) {
            const std::string message = status.errc.message();
            if (record.lastError != message) {
                record.lastError = message;
                sendError(TDNSString(record.id), TDNSString(message));
            }
            return;
        }

        if (!record.torrentInfo) {
            record.torrentInfo = record.handle.torrent_file();
        }
        const std::shared_ptr<const lt::torrent_info> &info = record.torrentInfo;
        if (!record.contentRoot.empty() && record.destination != record.contentRoot) {
            if (info && record.layoutName.empty() && !record.layoutFailed) {
                prepareTorrentLayout(record, *info);
            }
            // File paths and completion must describe the final location.
            return;
        }
        if (info && !record.addedEmitted) {
            sendEvent(addedPayload(record, status, *info));
            record.addedEmitted = true;
        }

        const bool seedProgressReady = !record.recheckPending && status.has_metadata
            && status.state != lt::torrent_status::checking_resume_data
            && status.state != lt::torrent_status::checking_files
            && status.state != lt::torrent_status::downloading_metadata;
        record.seedingClock.sample(seedProgressReady, status.is_finished,
                                   status.finished_duration.count(), status.all_time_upload);
        sendEvent(progressPayload(record, status));

        // Report verified completion before a policy pause or removal so the
        // completion update cannot clear the reason for stopping seeding.
        if (seedProgressReady && !status.is_finished) {
            record.doneEmitted = false;
            record.completionFlushPending = false;
            record.completionFlushed = false;
        }
        if (info && seedProgressReady && status.is_finished && !record.doneEmitted) {
            // Piece hashes may finish before the final buffered writes reach the
            // filesystem. Wait for libtorrent's disk barrier before the app
            // validates or exposes the completed files, or a policy removes them.
            if (!record.seedOnly && !record.completionFlushed) {
                if (!record.completionFlushPending) {
                    record.completionFlushPending = true;
                    record.handle.flush_cache();
                }
                return;
            }
            sendEvent(donePayload(record, status, *info));
            record.doneEmitted = true;
        }

        // Enforce all seeding limits in the engine, including headless mode.
        // Downloading and verification must finish before a limit can act.
        const std::int64_t downloaded = std::max<std::int64_t>(status.total_wanted_done, 0);
        const std::int64_t uploaded = std::max<std::int64_t>(status.all_time_upload, 0);
        const double ratio = downloaded > 0
            ? static_cast<double>(uploaded) / static_cast<double>(downloaded) : 0.0;
        const char *limitReason = TDReachedSeedingLimit(seedProgressReady && status.is_finished
            && !bool(status.flags & lt::torrent_flags::paused), ratio, record.shareRatioLimit,
            record.seedingClock, record.seedingTimeLimitSeconds, record.inactiveSeedingTimeLimitSeconds);
        if (!record.shareRatioTriggered && record.shareRatioAction != 0 && limitReason != nullptr) {
            record.shareRatioTriggered = true;
            const std::string id = record.id;
            if (record.shareRatioAction == 1) {
                record.pauseRequested = true;
                record.handle.pause();
                const bool ratioReached = std::string(limitReason) == "ratio";
                sendEvent(@{ @"type": ratioReached ? @"shareRatioReached" : @"seedingLimitReached",
                             @"reason": TDNSString(limitReason),
                             @"id": TDNSString(id),
                             @"action": @"pause" });
            } else if (record.shareRatioAction == 2) {
                session_.remove_torrent(record.handle, lt::remove_flags_t{});
                torrents_.erase(it);
                peerDetailSubscriptions_.erase(id);
                resumeStore_.remove(id);
                std::remove(resumeDataPath(id).c_str());
                sendEvent(@{ @"type": @"cancelled", @"id": TDNSString(id) });
                return;
            }
        }

    }

    void pollPeerDetails(const std::string &id) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(id);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
        try {
            const lt::torrent_status status = it->second.handle.status(
                lt::torrent_handle::query_distributed_copies);
            sendEvent(peerPayload(it->second, status));
        } catch (const std::exception &ex) {
            if (it->second.lastError != ex.what()) {
                it->second.lastError = ex.what();
                sendError(TDNSString(id), TDNSString(it->second.lastError));
            }
        }
    }

    void sendError(NSString *identifier, NSString *message) {
        NSMutableDictionary *payload = [@{
            @"type": @"error",
            @"message": message ?: @"Unknown error"
        } mutableCopy];
        if (identifier != nil) {
            payload[@"id"] = identifier;
        }
        sendEvent(payload);
    }

    void sendEvent(NSDictionary *payload) {
        @autoreleasepool {
            std::lock_guard<std::mutex> lock(outputMutex_);
            NSError *error = nil;
            NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
            if (json == nil) {
                std::cerr << "{\"type\":\"error\",\"message\":\"Failed to encode helper event\"}\n";
                std::cerr.flush();
                return;
            }
            std::cout.write(static_cast<const char *>(json.bytes), static_cast<std::streamsize>(json.length));
            std::cout.put('\n');
            std::cout.flush();
        }
    }
