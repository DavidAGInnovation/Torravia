// Alert polling, resume persistence, and alert-to-event translation for Helper.

    void pollAlerts() {
        std::vector<lt::alert *> alerts;
        session_.pop_alerts(&alerts);
        for (lt::alert *alert : alerts) {
            if (peerDiagnosticsEnabled_
                && bool(alert->category() & (lt::alert_category::peer | lt::alert_category::connect))) {
                std::fprintf(stderr, "%s: %s\n", alert->what(), alert->message().c_str());
            }
            processAlert(alert);
        }
    }

    void requestResumeDataSave(const std::string &id) {
        lt::torrent_handle handle;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = torrents_.find(id);
            if (it == torrents_.end() || !it->second.handle.is_valid()
                || it->second.resumeSavePending) {
                return;
            }
            it->second.resumeSavePending = true;
            handle = it->second.handle;
        }
        try {
            handle.save_resume_data(lt::torrent_handle::save_info_dict
                                    | lt::torrent_handle::only_if_modified);
        } catch (...) {
            clearResumeSavePending(handle);
        }
    }

    void requestResumeDataSaves() {
        std::vector<lt::torrent_handle> handles;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (auto &entry : torrents_) {
                if (entry.second.handle.is_valid() && !entry.second.resumeSavePending) {
                    entry.second.resumeSavePending = true;
                    handles.push_back(entry.second.handle);
                }
            }
        }

        for (const auto &handle : handles) {
            try {
                handle.save_resume_data(lt::torrent_handle::save_info_dict
                                        | lt::torrent_handle::only_if_modified);
            } catch (...) {
                clearResumeSavePending(handle);
            }
        }
    }

    void clearResumeSavePending(const lt::torrent_handle &handle) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto &entry : torrents_) {
            if (entry.second.handle == handle) {
                entry.second.resumeSavePending = false;
                return;
            }
        }
    }

    std::string torrentIDForHandle(const lt::torrent_handle &handle) {
        if (!handle.is_valid()) { return {}; }
        std::lock_guard<std::mutex> lock(mutex_);
        for (const auto &entry : torrents_) {
            if (entry.second.handle == handle) {
                return entry.first;
            }
        }
        return {};
    }

    static const char *portMapTransportName(lt::portmap_transport transport) {
        switch (transport) {
            case lt::portmap_transport::upnp:
                return "UPnP";
            case lt::portmap_transport::natpmp:
                return "NAT-PMP";
        }
        return "Port mapping";
    }

    void processAlert(lt::alert *alert) {
        if (alert == nullptr) { return; }

        if (auto *added = lt::alert_cast<lt::add_torrent_alert>(alert)) {
            PendingTorrentAdd *pendingRaw = added->params.userdata.get<PendingTorrentAdd>();
            if (pendingRaw == nullptr) { return; }

            std::shared_ptr<PendingTorrentAdd> pending;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = pendingAdds_.find(pendingRaw->id);
                if (it == pendingAdds_.end() || it->second.get() != pendingRaw) {
                    // The helper is shutting down or the request was already
                    // completed. Do not claim an unrelated add alert.
                    return;
                }
                pending = it->second;
            }

            if (added->error) {
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    auto it = pendingAdds_.find(pending->id);
                    if (it != pendingAdds_.end() && it->second.get() == pending.get()) {
                        pendingAdds_.erase(it);
                    }
                }
                if (!pending->cancelRequested) {
                    sendError(TDNSString(pending->id), TDNSString(added->error.message()));
                }
                return;
            }

            finishTorrentAdd(pending, added->handle);
            return;
        }

        if (auto *connected = lt::alert_cast<lt::peer_connect_alert>(alert)) {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = std::find_if(torrents_.begin(), torrents_.end(), [&](const auto &entry) {
                return entry.second.handle == connected->handle;
            });
            if (it != torrents_.end()) {
                TorrentRecord &record = it->second;
                ++record.peerConnectSuccesses;
                record.peerConnectSuccessEwma = record.peerConnectSuccessEwma == 0.0
                    ? 1.0 : (record.peerConnectSuccessEwma * 0.9) + 0.1;
            }
            return;
        }

        if (auto *peerError = lt::alert_cast<lt::peer_error_alert>(alert)) {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = std::find_if(torrents_.begin(), torrents_.end(), [&](const auto &entry) {
                return entry.second.handle == peerError->handle;
            });
            if (it != torrents_.end()) {
                TorrentRecord &record = it->second;
                ++record.peerConnectFailures;
                record.peerConnectSuccessEwma *= 0.9;
            }
            return;
        }

        if (auto *performance = lt::alert_cast<lt::performance_alert>(alert)) {
            std::string adjustment;
            const std::string id = torrentIDForHandle(performance->handle);
            {
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = torrents_.find(id);
                if (it != torrents_.end()) {
                    TorrentRecord &record = it->second;
                    const lt::torrent_status status = record.handle.status();
                    const double currentRate = status.download_payload_rate > 0
                        ? status.download_payload_rate : status.download_rate;
                    const auto armBufferMonitoring = [&] {
                        record.adaptiveBaselineRate = std::max(
                            {record.adaptiveBaselineRate, record.throughputEwma, currentRate});
                        record.adaptiveWarningAt = std::chrono::steady_clock::now();
                    };
                    switch (performance->warning_code) {
                        case lt::performance_alert::outstanding_disk_buffer_limit_reached:
                            armBufferMonitoring();
                            record.pendingDiskQueueIncrease = true;
                            ++record.diskLimitWarnings;
                            adjustment = "Monitoring disk queue pressure";
                            break;
                        case lt::performance_alert::outstanding_request_limit_reached:
                            ++record.requestLimitWarnings;
                            // Remote peers may advertise a smaller reqq.
                            // Count pressure for diagnostics; a session change
                            // cannot enlarge an already connected peer's cap.
                            break;
                        case lt::performance_alert::send_buffer_watermark_too_low:
                            armBufferMonitoring();
                            record.pendingSendBufferIncrease = true;
                            adjustment = "Monitoring upload buffer pressure";
                            break;
                        default:
                            break;
                    }
                }
            }
            switch (performance->warning_code) {
                case lt::performance_alert::too_few_outgoing_ports:
                    {
                    lt::settings_pack tuning;
                    tuning.set_int(lt::settings_pack::outgoing_port, 0);
                    tuning.set_int(lt::settings_pack::num_outgoing_ports, 0);
                    session_.apply_settings(std::move(tuning));
                    adjustment = "Released the restrictive outgoing port range";
                    }
                    break;
                default:
                    break;
            }
            if (!adjustment.empty()) {
                applyAdaptiveSessionSettings();
                sendEvent(@{@"type": @"warning",
                            @"id": TDNSString(id),
                            @"message": TDNSString(adjustment + " automatically.")});
            }
            return;
        }

        if (auto *fileError = lt::alert_cast<lt::file_error_alert>(alert)) {
            const std::string id = torrentIDForHandle(fileError->handle);
            if (!id.empty()) {
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = torrents_.find(id);
                if (it != torrents_.end()) {
                    it->second.pauseRequested = true;
                    it->second.handle.pause();
                }
            }
            sendEvent(@{@"type": @"storageError",
                        @"id": TDNSString(id),
                        @"message": TDNSString(fileError->message())});
            return;
        }

        if (auto *renamed = lt::alert_cast<lt::file_renamed_alert>(alert)) {
            std::lock_guard<std::mutex> lock(mutex_);
            for (auto &entry : torrents_) {
                auto &record = entry.second;
                if (record.handle != renamed->handle || record.layoutRenamesPending == 0) { continue; }
                if (--record.layoutRenamesPending == 0 && !record.layoutFailed) {
                    moveTorrentToContentRoot(record);
                }
                return;
            }
        }

        if (auto *moved = lt::alert_cast<lt::storage_moved_alert>(alert)) {
            std::string id;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                for (auto &entry : torrents_) {
                    auto &record = entry.second;
                    if (record.handle != moved->handle || !record.layoutMoving) { continue; }
                    const std::string staging = record.destination;
                    record.destination = record.contentRoot;
                    record.layoutMoving = false;
                    record.addedEmitted = false;
                    id = record.id;
                    // rmdir only removes empty directories; it cannot remove
                    // files owned by this or another download.
                    ::rmdir(staging.c_str());
                    NSString *parent = [TDNSString(staging) stringByDeletingLastPathComponent];
                    if ([parent.lastPathComponent isEqualToString:@".TorrentScout"]) {
                        ::rmdir(parent.fileSystemRepresentation);
                    }
                    break;
                }
            }
            if (!id.empty()) {
                requestResumeDataSave(id);
                session_.post_torrent_updates();
            }
            return;
        }

        if (auto *moveFailed = lt::alert_cast<lt::storage_moved_failed_alert>(alert)) {
            const std::string id = torrentIDForHandle(moveFailed->handle);
            {
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = torrents_.find(id);
                if (it != torrents_.end() && it->second.layoutMoving) {
                    failTorrentLayout(it->second, moveFailed->message());
                    return;
                }
            }
            sendEvent(@{@"type": @"storageError",
                        @"id": TDNSString(id),
                        @"message": TDNSString(moveFailed->message())});
            return;
        }

        if (auto *renameFailed = lt::alert_cast<lt::file_rename_failed_alert>(alert)) {
            const std::string id = torrentIDForHandle(renameFailed->handle);
            {
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = torrents_.find(id);
                if (it != torrents_.end() && it->second.layoutRenamesPending > 0) {
                    failTorrentLayout(it->second, renameFailed->message());
                    return;
                }
            }
            sendEvent(@{@"type": @"warning",
                        @"id": TDNSString(id),
                        @"message": TDNSString(renameFailed->message())});
            return;
        }

        if (auto *deleteFailed = lt::alert_cast<lt::torrent_delete_failed_alert>(alert)) {
            const std::string id = torrentIDForHandle(deleteFailed->handle);
            sendEvent(@{@"type": @"warning",
                        @"id": TDNSString(id),
                        @"message": TDNSString(deleteFailed->message())});
            return;
        }

        if (auto *conflict = lt::alert_cast<lt::torrent_conflict_alert>(alert)) {
            const std::string id = torrentIDForHandle(conflict->handle);
            sendError(id.empty() ? nil : TDNSString(id), TDNSString(conflict->message()));
            return;
        }

        if (auto *dropped = lt::alert_cast<lt::alerts_dropped_alert>(alert)) {
            ++alertsDropped_;
            networkStatusDirty_ = true;
            sendEvent(@{@"type": @"warning",
                        @"message": TDNSString(dropped->message()),
                        @"alertsDropped": @(alertsDropped_)});
            return;
        }

        if (auto *saved = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
            const std::string id = torrentIDForHandle(saved->handle);
            if (!id.empty()) {
                try {
                    enqueueResumeWrite(id, lt::write_resume_data_buf(saved->params));
                } catch (...) {
                    sendEvent(@{@"type": @"warning",
                                @"id": TDNSString(id),
                                @"message": @"Resume snapshot could not be encoded."});
                }
            }
            clearResumeSavePending(saved->handle);
            return;
        }

        if (auto *checked = lt::alert_cast<lt::torrent_checked_alert>(alert)) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                for (auto &entry : torrents_) {
                    if (entry.second.handle == checked->handle) {
                        if (entry.second.seedOnly && !checked->handle.status().is_seeding) {
                            failTorrentLayout(entry.second, "The original files do not match this torrent's piece hashes. No content was downloaded or replaced.");
                            return;
                        }
                        entry.second.recheckPending = false;
                        break;
                    }
                }
            }
            // force_recheck is asynchronous: completion snapshots received
            // before this alert still describe the previous verification.
            try { processTorrentStatus(checked->handle.status()); }
            catch (const std::exception &) { }
            return;
        }

        if (auto *flushed = lt::alert_cast<lt::cache_flushed_alert>(alert)) {
            bool completionReady = false;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                for (auto &entry : torrents_) {
                    auto &record = entry.second;
                    if (record.handle == flushed->handle && record.completionFlushPending) {
                        record.completionFlushPending = false;
                        record.completionFlushed = true;
                        completionReady = true;
                        break;
                    }
                }
            }
            if (completionReady) {
                try { processTorrentStatus(flushed->handle.status()); }
                catch (const std::exception &) { }
            }
            return;
        }

        if (auto *finished = lt::alert_cast<lt::torrent_finished_alert>(alert)) {
            // Completion is an engine event. Publish it immediately instead
            // of waiting up to 1.5 seconds for the periodic progress update.
            try {
                processTorrentStatus(finished->handle.status());
            } catch (const std::exception &) {
                // The torrent may have been removed by a concurrent command.
            }
            return;
        }

        if (auto *updates = lt::alert_cast<lt::state_update_alert>(alert)) {
            for (const lt::torrent_status &status : updates->status) {
                processTorrentStatus(status);
            }
            return;
        }

        if (auto *rejected = lt::alert_cast<lt::fastresume_rejected_alert>(alert)) {
            const std::string id = torrentIDForHandle(rejected->handle);
            if (!id.empty()) {
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    auto it = torrents_.find(id);
                    if (it != torrents_.end()) {
                        // The fast-resume snapshot is no longer trustworthy
                        // (usually because a file was moved, replaced, or
                        // partially removed). Drop it and let libtorrent
                        // verify the files immediately instead of pausing the
                        // torrent behind an error that requires a click.
                        it->second.resumeRejected = false;
                        it->second.pauseRequested = false;
                        it->second.doneEmitted = false;
                        it->second.recheckPending = true;
                        resumeStore_.remove(id);
                        std::remove(resumeDataPath(id).c_str());
                        it->second.handle.force_recheck();
                        it->second.handle.resume();
                    }
                }
                sendEvent(@{ @"type": @"resumeRechecking",
                             @"id": TDNSString(id),
                             @"message": @"Saved download state was stale; verifying existing files…" });
            }
            return;
        }

        if (auto *stats = lt::alert_cast<lt::session_stats_alert>(alert)) {
            const auto counters = stats->counters();
            if (dhtNodesMetricIndex_ >= 0
                && dhtNodesMetricIndex_ < static_cast<int>(counters.size())) {
                dhtNodes_ = static_cast<int>(std::max<std::int64_t>(
                    counters[dhtNodesMetricIndex_], 0));
            }
            return;
        }

        if (auto *failed = lt::alert_cast<lt::save_resume_data_failed_alert>(alert)) {
            const std::string id = torrentIDForHandle(failed->handle);
            clearResumeSavePending(failed->handle);
            // `only_if_modified` deliberately reports this condition when
            // nothing changed since the last snapshot. It is a successful
            // no-op, not a persistence failure, and should never become an
            // orange warning in the download row.
            if (failed->error == lt::errors::resume_data_not_modified) {
                return;
            }
            sendEvent(@{ @"type": @"warning",
                         @"id": TDNSString(id),
                         @"message": TDNSString("Resume snapshot failed: " + failed->message()) });
            return;
        }

        if (auto *succeeded = lt::alert_cast<lt::listen_succeeded_alert>(alert)) {
            const bool recoveredListening = listenRecoveryPending_.exchange(false);
            listenPort_ = succeeded->port;
            listenState_ = "listening";
            networkStatusDirty_ = true;
            if (recoveredListening) {
                reannounceAfterListenRecovery();
            }
            return;
        }

        if (auto *failed = lt::alert_cast<lt::listen_failed_alert>(alert)) {
            listenPort_ = 0;
            listenState_ = "failed: " + failed->error.message();
            // A failed bind can be followed by libtorrent's
            // listen_system_port_fallback retry on an OS-selected port. Only
            // mark recovery pending when no other listen socket is active, so
            // a failure on one interface does not trigger an unnecessary
            // reannounce while another interface is already listening.
            if (!session_.is_listening()) {
                const bool firstFailure = !listenRecoveryPending_.exchange(true);
                if (firstFailure) {
                    sendEvent(@{
                        @"type": @"warning",
                        @"message": [NSString stringWithFormat:
                            @"Listening on the requested port failed (%@); retrying with an OS-selected port.",
                            TDNSString(failed->error.message())]
                    });
                }
            }
            networkStatusDirty_ = true;
            return;
        }

        if (auto *mapped = lt::alert_cast<lt::portmap_alert>(alert)) {
            const std::string status = std::string("mapped on ")
                + portMapTransportName(mapped->map_transport)
                + " (port " + std::to_string(mapped->external_port) + ")";
            if (mapped->map_transport == lt::portmap_transport::upnp) {
                upnpStatus_ = status;
            } else {
                natpmpStatus_ = status;
            }
            networkStatusDirty_ = true;
            return;
        }

        if (auto *mappingError = lt::alert_cast<lt::portmap_error_alert>(alert)) {
            const std::string status = std::string("failed on ")
                + portMapTransportName(mappingError->map_transport)
                + ": " + mappingError->error.message();
            if (mappingError->map_transport == lt::portmap_transport::upnp) {
                upnpStatus_ = status;
            } else {
                natpmpStatus_ = status;
            }
            networkStatusDirty_ = true;
            return;
        }

        if (auto *announce = lt::alert_cast<lt::tracker_announce_alert>(alert)) {
            ++trackerAnnounces_;
            trackerStatus_ = "announcing";
            lastTrackerURL_ = announce->tracker_url() ?: "";
            networkStatusDirty_ = true;
            return;
        }

        if (auto *reply = lt::alert_cast<lt::tracker_reply_alert>(alert)) {
            ++trackerReplies_;
            trackerStatus_ = reply->num_peers > 0 ? "receiving peers" : "announced";
            lastTrackerURL_ = reply->tracker_url() ?: "";
            const std::string id = torrentIDForHandle(reply->handle);
            if (!id.empty()) {
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    auto it = torrents_.find(id);
                    if (it != torrents_.end()) {
                        it->second.trackerReplyPeers = std::max(
                            it->second.trackerReplyPeers, std::max(reply->num_peers, -1));
                        auto &health = it->second.trackerHealth[
                            TDLowercase(reply->tracker_url() ?: "")];
                        health.successes += 1;
                        health.lastPeerCount = std::max(reply->num_peers, 0);
                        health.consecutiveFailures = 0;
                        health.cooldownUntil = {};
                    }
                }
                // Tracker scrape values are carried by tracker state and may
                // not appear in every periodic torrent-status update. Push a
                // discovery snapshot immediately so the UI receives the
                // latest swarm estimate without a manual refresh.
                sendDiscovery(id);
            }
            networkStatusDirty_ = true;
            return;
        }

        if (auto *dhtReply = lt::alert_cast<lt::dht_reply_alert>(alert)) {
            ++dhtReplies_;
            dhtStatus_ = "active";
            if (dhtReply->tracker_url() != nullptr) {
                lastTrackerURL_ = dhtReply->tracker_url();
            }
            networkStatusDirty_ = true;
            return;
        }

        if (auto *error = lt::alert_cast<lt::tracker_error_alert>(alert)) {
            ++trackerErrors_;
            trackerStatus_ = "tracker error";
            const std::string trackerURL = error->tracker_url() ?: "";
            lastTrackerURL_ = trackerURL;
            lastTrackerError_ = error->message();
            const std::string id = torrentIDForHandle(error->handle);
            if (!id.empty() && !trackerURL.empty()) {
                noteTrackerFailure(id, trackerURL, error->times_in_row);
            }
            networkStatusDirty_ = true;
            return;
        }

        if (auto *warning = lt::alert_cast<lt::tracker_warning_alert>(alert)) {
            trackerStatus_ = "warning";
            lastTrackerURL_ = warning->tracker_url() ?: "";
            lastTrackerError_ = warning->message();
            networkStatusDirty_ = true;
            return;
        }

        if (auto *bootstrap = lt::alert_cast<lt::dht_bootstrap_alert>(alert)) {
            (void)bootstrap;
            dhtStatus_ = "ready";
            networkStatusDirty_ = true;
        }
    }
