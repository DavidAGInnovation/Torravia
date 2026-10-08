// Torrent add/resume lifecycle and per-torrent configuration for Helper.

    void failTorrentLayout(TorrentRecord &record, const std::string &message) {
        record.layoutFailed = true;
        record.pauseRequested = true;
        record.handle.pause();
        sendEvent(@{@"type": @"storageError", @"id": TDNSString(record.id),
                    @"message": TDNSString(message)});
    }

    void moveTorrentToContentRoot(TorrentRecord &record) {
        record.layoutMoving = true;
        record.handle.move_storage(record.contentRoot, lt::move_flags_t::fail_if_exist);
    }

    // Called with mutex_ held. Metadata-less magnets first use an isolated
    // staging directory so no file can touch an unrelated download before
    // its real name is known. Rename collisions through libtorrent so the
    // mapping survives fast-resume and piece hashes remain unchanged.
    void prepareTorrentLayout(TorrentRecord &record, const lt::torrent_info &info) {
        const auto &files = info.layout();
        const auto renames = record.handle.get_renamed_files();
        std::string originalRoot;
        bool directory = false;
        for (auto index : files.file_range()) {
            if (files.pad_file_at(index)) { continue; }
            const auto path = renames.file_path(files, index);
            const auto slash = path.find('/');
            const auto root = path.substr(0, slash);
            if (root.empty() || root == "." || root == ".."
                || (!originalRoot.empty() && root != originalRoot)) {
                failTorrentLayout(record, "Torrent files do not share a safe content path.");
                return;
            }
            originalRoot = root;
            directory = directory || slash != std::string::npos;
        }
        if (originalRoot.empty()) {
            failTorrentLayout(record, "Torrent has no downloadable files.");
            return;
        }

        NSFileManager *manager = [NSFileManager defaultManager];
        NSString *parent = TDNSString(record.contentRoot);
        NSError *error = nil;
        if (![manager createDirectoryAtPath:parent withIntermediateDirectories:YES
                                  attributes:nil error:&error]) {
            failTorrentLayout(record, TDStdString(error.localizedDescription));
            return;
        }
        NSString *base = TDNSString(originalRoot);
        NSString *extension = directory ? @"" : base.pathExtension;
        NSString *stem = extension.length == 0 ? base : base.stringByDeletingPathExtension;
        for (int suffix = 1; ; ++suffix) {
            NSString *name = suffix == 1 ? base
                : [NSString stringWithFormat:@"%@-%d%@%@", stem, suffix,
                    extension.length == 0 ? @"" : @".", extension];
            NSString *candidate = [parent stringByAppendingPathComponent:name];
            bool reserved = false;
            for (const auto &entry : torrents_) {
                if (entry.first != record.id
                    && [TDNSString(entry.second.contentRoot) caseInsensitiveCompare:parent] == NSOrderedSame
                    && [TDNSString(entry.second.layoutName) caseInsensitiveCompare:name] == NSOrderedSame) {
                    reserved = true;
                    break;
                }
            }
            if (reserved || [manager fileExistsAtPath:candidate]) { continue; }
            // Reserve directory names atomically across helper instances.
            if (directory && ![manager createDirectoryAtPath:candidate
                withIntermediateDirectories:NO attributes:nil error:&error]) {
                if ([manager fileExistsAtPath:candidate]) { continue; }
                failTorrentLayout(record, TDStdString(error.localizedDescription));
                return;
            }
            record.layoutName = TDStdString(name);
            break;
        }

        for (auto index : files.file_range()) {
            const auto path = renames.file_path(files, index);
            const auto slash = path.find('/');
            const auto root = path.substr(0, slash);
            std::string replacement;
            if (root == originalRoot) {
                replacement = record.layoutName + (slash == std::string::npos ? "" : path.substr(slash));
            } else if (files.pad_file_at(index)) {
                replacement = record.layoutName + "/" + path;
            }
            if (!replacement.empty() && replacement != path) {
                ++record.layoutRenamesPending;
                record.handle.rename_file(index, replacement);
            }
        }
        if (record.layoutRenamesPending == 0) { moveTorrentToContentRoot(record); }
    }

    lt::add_torrent_params makeAddParams(const std::string &input,
                                         const std::string &destination,
                                         const std::string &id,
                                         std::string &errorMessage,
                                         std::string &resumeWarning,
                                         const std::string &contentRoot, NSArray *filePaths, bool seedOnly) {
        lt::error_code ec;
        lt::add_torrent_params params;

        if (TDHasPrefix(input, "magnet:")) {
            params = lt::parse_magnet_uri(input, ec);
            if (ec) {
                errorMessage = ec.message();
                return {};
            }
        } else if (TDHasPrefix(input, "http://") || TDHasPrefix(input, "https://")) {
            auto fetched = TDFetchURLData(input, errorMessage);
            if (!fetched) { return {}; }
            try {
                params = lt::load_torrent_buffer({fetched->data(), static_cast<int>(fetched->size())});
            } catch (const std::exception &ex) {
                errorMessage = ex.what();
                return {};
            }
        } else {
            auto data = TDReadFileData(input, errorMessage);
            if (!data) { return {}; }
            try {
                params = lt::load_torrent_buffer({data->data(), static_cast<int>(data->size())});
            } catch (const std::exception &ex) {
                errorMessage = ex.what();
                return {};
            }
        }

        if (seedOnly && (!params.ti || contentRoot != destination || contentRoot.empty())) {
            errorMessage = "Seeding originals requires torrent metadata and its original content folder.";
            return {};
        }
        const lt::add_torrent_params sourceParams = params;
        std::vector<std::vector<char>> snapshots = seedOnly ? std::vector<std::vector<char>>{} : resumeStore_.load(id);
        if (!seedOnly && snapshots.empty()) {
            std::ifstream resumeInput(resumeDataPath(id), std::ios::binary);
            if (resumeInput) {
                snapshots.emplace_back(std::istreambuf_iterator<char>(resumeInput),
                                       std::istreambuf_iterator<char>());
            }
        }

        bool restored = false;
        bool resumeDataRejected = false;
        bool resumeHashMismatch = false;
        for (const auto &data : snapshots) {
            if (data.empty()) { continue; }
            try {
                lt::add_torrent_params candidate = lt::read_resume_data(
                    {data.data(), static_cast<std::ptrdiff_t>(data.size())});
                if (!TDResumeMatchesSource(sourceParams, candidate)) {
                    resumeHashMismatch = true;
                    continue;
                }
                params = std::move(candidate);
                if (sourceParams.ti) { params.ti = sourceParams.ti; }
                if (sourceParams.info_hashes.has_v1() || sourceParams.info_hashes.has_v2()) {
                    params.info_hashes = sourceParams.info_hashes;
                }
                // Preserve the tracker list from fast-resume when it exists:
                // it includes trackers removed after their first failure. Only
                // fall back to the source magnet/torrent list when the
                // snapshot has no trackers at all.
                if (params.trackers.empty() && !sourceParams.trackers.empty()) {
                    params.trackers = sourceParams.trackers;
                    params.tracker_tiers = sourceParams.tracker_tiers;
                }
                resumeStore_.save(id, data);
                restored = true;
                break;
            } catch (...) {
                resumeDataRejected = true;
                params = sourceParams;
            }
        }
        if (!snapshots.empty() && !restored && resumeHashMismatch) {
            // This is a stale snapshot for another magnet, not a damaged
            // resume for the current one. Discard it and start the current
            // torrent immediately so it can discover and connect to its own
            // swarm instead of being paused behind a misleading warning.
            params = sourceParams;
            resumeDataRejected = false;
            resumeStore_.remove(id);
            std::remove(resumeDataPath(id).c_str());
        } else if (!snapshots.empty() && !restored) {
            // Existing payload files remain authoritative. Start from the
            // source metadata and let the caller perform a full verification
            // instead of trusting a damaged fast-resume snapshot.
            params = sourceParams;
            if (resumeDataRejected) {
                resumeWarning = "Saved download state was rejected; existing files will be verified before resuming.";
            }
        }

        // The helper may have finished placement just before the app saved
        // its new path. Prefer that durable location over the old staging path.
        if (!restored || contentRoot.empty() || params.save_path != contentRoot) {
            params.save_path = destination;
        }
        // The app also persists the effective filenames. Recover these
        // mappings when helper resume data is missing or rejected, instead of
        // falling back to another torrent's original, now occupied filename.
        if (!contentRoot.empty() && params.save_path == contentRoot
            && [filePaths isKindOfClass:[NSArray class]]) {
            int physicalFileCount = 0;
            if (params.ti) {
                for (auto index : params.ti->layout().file_range()) {
                    if (!params.ti->layout().pad_file_at(index)) ++physicalFileCount;
                }
            }
            const bool physicalPathsOnly = params.ti && filePaths.count == static_cast<NSUInteger>(physicalFileCount);
            if (params.ti && !physicalPathsOnly && filePaths.count != static_cast<NSUInteger>(params.ti->num_files())) {
                errorMessage = "Saved torrent file layout does not match its metadata.";
                return {};
            }
            int index = 0;
            for (NSObject *value in filePaths) {
                if (![value isKindOfClass:[NSString class]]) {
                    errorMessage = "Saved torrent file layout is invalid.";
                    return {};
                }
                NSString *path = (NSString *)value;
                if (path.length == 0 || path.isAbsolutePath
                    || [path.pathComponents containsObject:@".."]
                    || [path.pathComponents containsObject:@"."]) {
                    errorMessage = "Saved torrent file layout is invalid.";
                    return {};
                }
                if (physicalPathsOnly) {
                    while (index < params.ti->num_files() && params.ti->layout().pad_file_at(lt::file_index_t{index})) ++index;
                }
                params.renamed_files[lt::file_index_t{index++}] = TDStdString(path);
            }
        }
        params.storage_mode = preallocateFiles_ && !seedOnly
            ? lt::storage_mode_allocate : lt::storage_mode_sparse;
        if (seedOnly) {
            // Refuse missing originals before libtorrent can initialize storage.
            // Recheck on every load rather than trusting a previous resume snapshot.
            for (auto index : params.ti->layout().file_range()) {
                if (params.ti->layout().pad_file_at(index)) { continue; }
                auto renamed = params.renamed_files.find(index);
                const auto relative = renamed == params.renamed_files.end()
                    ? params.ti->layout().file_path(index) : renamed->second;
                NSString *relativePath = TDNSString(relative);
                if (relativePath.isAbsolutePath || [relativePath.pathComponents containsObject:@".."]
                    || [relativePath.pathComponents containsObject:@"."]) {
                    errorMessage = "Original content paths must remain inside their selected folder.";
                    return {};
                }
                NSString *path = [TDNSString(destination) stringByAppendingPathComponent:relativePath];
                auto attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
                if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular]
                    || [attributes[NSFileSize] longLongValue] != params.ti->layout().file_size(index)) {
                    errorMessage = "Original files are missing or have changed size; seeding was not started.";
                    return {};
                }
            }
        }
        params.flags &= ~lt::torrent_flags::paused;
        params.flags &= ~lt::torrent_flags::auto_managed;
        params.flags &= ~lt::torrent_flags::duplicate_is_error;
        params.flags |= lt::torrent_flags::update_subscribe;
        if (seedOnly) {
            params.flags |= lt::torrent_flags::upload_mode;
            params.flags &= ~lt::torrent_flags::seed_mode;
        }
        appendConfiguredTrackers(params);
        if (!dhtEnabled_) params.flags |= lt::torrent_flags::disable_dht;
        if (!peerExchangeEnabled_) params.flags |= lt::torrent_flags::disable_pex;
        if (!localPeerDiscoveryEnabled_) params.flags |= lt::torrent_flags::disable_lsd;
        params.max_connections = perTorrentConnectionLimit_;
        params.max_uploads = perTorrentUploadSlots_;
        if (queueingEnabled_ && !seedOnly) {
            params.flags |= lt::torrent_flags::auto_managed;
        }
        return params;
    }

    void finishTorrentAdd(const std::shared_ptr<PendingTorrentAdd> &pending,
                          const lt::torrent_handle &handle) {
        if (!pending || !handle.is_valid()) {
            if (pending) {
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = pendingAdds_.find(pending->id);
                if (it != pendingAdds_.end() && it->second.get() == pending.get()) {
                    pendingAdds_.erase(it);
                }
                sendError(TDNSString(pending->id), @"Torrent could not be added");
            }
            return;
        }

        bool duplicate = false;
        bool cancelled = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto pendingIt = pendingAdds_.find(pending->id);
            if (pendingIt == pendingAdds_.end() || pendingIt->second.get() != pending.get()) {
                return;
            }
            if (pending->cancelRequested) {
                cancelled = true;
                pendingAdds_.erase(pendingIt);
            } else if (torrents_.find(pending->id) != torrents_.end()) {
                duplicate = true;
                pendingAdds_.erase(pendingIt);
            } else {
                TorrentRecord record;
                record.id = pending->id;
                record.input = pending->input;
                record.destination = pending->destination;
                record.contentRoot = pending->contentRoot;
                record.seedOnly = pending->seedOnly;
                record.recheckPending = pending->seedOnly;
                record.handle = handle;
                record.torrentInfo = handle.torrent_file();
                if (record.torrentInfo && !record.contentRoot.empty()
                    && record.destination == record.contentRoot) {
                    const auto renames = handle.get_renamed_files();
                    for (auto index : record.torrentInfo->layout().file_range()) {
                        if (record.torrentInfo->layout().pad_file_at(index)) { continue; }
                        const auto path = renames.file_path(record.torrentInfo->layout(), index);
                        record.layoutName = path.substr(0, path.find('/'));
                        break;
                    }
                }
                // Keep the userdata cookie alive for the lifetime of the
                // torrent. libtorrent retains it on the handle after the
                // add_torrent_alert has been delivered.
                record.asyncAddUserData = pending;
                // A rejected snapshot is recoverable: verify the files against
                // the torrent metadata and continue from the pieces that still
                // match. Do not leave the torrent paused behind a startup-only
                // warning.
                record.pauseRequested = pending->pauseRequested;
                record.resumeRejected = false;
                record.storageKind = pending->storageKind;
                record.nextDiscoveryAttempt = std::chrono::steady_clock::now();
                // The add path sends an immediate high-priority announce;
                // keep the recovery scheduler from duplicating it on this pass.
                record.nextTrackerAnnounce = std::chrono::steady_clock::now()
                    + std::chrono::seconds(180);
                torrents_[pending->id] = std::move(record);
                pendingAdds_.erase(pendingIt);
            }
        }

        if (duplicate) {
            session_.remove_torrent(handle, lt::remove_flags_t{});
            sendError(TDNSString(pending->id), @"Torrent is already loaded");
            return;
        }

        if (cancelled) {
            session_.remove_torrent(
                handle,
                pending->deleteData ? lt::session_handle::delete_files
                                    : lt::remove_flags_t{});
            return;
        }

        if (pending->pauseRequested) {
            handle.pause();
        }
        if (!pending->resumeWarning.empty()) {
            handle.force_recheck();
            if (!pending->pauseRequested) {
                handle.resume();
            }
        }

        refreshHashingThreadTuning();

        // Kick off both discovery paths immediately. This avoids waiting for
        // the first periodic announce when a magnet has just been restored or
        // when a rebuilt app is reconnecting to an existing swarm.
        try {
            handle.force_reannounce(0, -1, lt::torrent_handle::high_priority);
            handle.force_dht_announce();
            if (localPeerDiscoveryEnabled_) { handle.force_lsd_announce(); }
        } catch (...) {
            // The regular maintenance loop will retry if the announce cannot
            // be issued during initial torrent setup.
        }

        if (!pending->resumeWarning.empty()) {
            resumeStore_.remove(pending->id);
            std::remove(resumeDataPath(pending->id).c_str());
            sendEvent(@{
                @"type": @"resumeRechecking",
                @"id": TDNSString(pending->id),
                @"message": @"Saved download state was stale; verifying existing files…"
            });
        }

        session_.post_torrent_updates();

        if (pending->emitResumed) {
            sendEvent(@{@"type": @"resumed", @"id": TDNSString(pending->id)});
        }
    }

    void addTorrent(const std::string &id,
                    const std::string &input,
                    const std::string &destination,
                    bool emitResumed,
                    const std::string &contentRoot = {}, NSArray *filePaths = nil, bool seedOnly = false) {
        if (id.empty() || input.empty() || destination.empty()) {
            sendError(id.empty() ? nil : TDNSString(id), @"Missing torrent parameters");
            return;
        }

        std::string errorMessage;
        std::string resumeWarning;
        lt::add_torrent_params params = makeAddParams(
            input, destination, id, errorMessage, resumeWarning, contentRoot, filePaths, seedOnly);
        if (!errorMessage.empty()) {
            sendError(TDNSString(id), TDNSString(errorMessage));
            return;
        }

        auto pending = std::make_shared<PendingTorrentAdd>();
        pending->id = id;
        pending->input = input;
        pending->destination = params.save_path;
        pending->contentRoot = contentRoot;
        pending->seedOnly = seedOnly;
        pending->resumeWarning = std::move(resumeWarning);
        pending->storageKind = TDStorageKindForPath(destination);
        pending->emitResumed = emitResumed;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (torrents_.find(id) != torrents_.end()
                || pendingAdds_.find(id) != pendingAdds_.end()) {
                sendError(TDNSString(id), @"Torrent is already loaded or being added");
                return;
            }
            pendingAdds_[id] = pending;
        }

        // The add_torrent_params userdata cookie lets the corresponding
        // add_torrent_alert recover the caller metadata without blocking the
        // command reader while libtorrent checks files or loads metadata.
        params.userdata = pending.get();
        try {
            session_.async_add_torrent(std::move(params));
        } catch (const std::exception &ex) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                pendingAdds_.erase(id);
            }
            sendError(TDNSString(id), TDNSString(ex.what()));
        }
    }

    void resumeTorrent(const std::string &id,
                       const std::string &input,
                       const std::string &destination,
                       const std::string &contentRoot = {}, NSArray *filePaths = nil, bool seedOnly = false) {
        std::string resumeInput = input;
        std::string resumeDestination = destination;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto existing = torrents_.find(id);
            if (existing != torrents_.end() && existing->second.handle.is_valid()) {
                if (!destination.empty() && existing->second.destination != destination) {
                    if (resumeInput.empty()) {
                        resumeInput = existing->second.input;
                    }
                    session_.remove_torrent(existing->second.handle, lt::remove_flags_t{});
                    torrents_.erase(existing);
                } else {
                    existing->second.stopRequested = false;
                    existing->second.pauseRequested = false;
                    existing->second.shareRatioTriggered = false;
                    const bool needsVerification = existing->second.resumeRejected || existing->second.seedOnly;
                    existing->second.layoutFailed = false;
                    existing->second.recheckPending = needsVerification;
                    existing->second.resumeRejected = false;
                    if (queueingEnabled_ && !existing->second.seedOnly) {
                        existing->second.handle.set_flags(lt::torrent_flags::auto_managed);
                    } else {
                        existing->second.handle.unset_flags(lt::torrent_flags::auto_managed);
                    }
                    if (needsVerification) {
                        existing->second.handle.force_recheck();
                    }
                    existing->second.handle.resume();
                    existing->second.handle.force_reannounce(
                        0, -1, lt::torrent_handle::high_priority);
                    existing->second.handle.force_dht_announce();
                    if (localPeerDiscoveryEnabled_) {
                        existing->second.handle.force_lsd_announce();
                    }
                    sendEvent(@{@"type": @"resumed", @"id": TDNSString(id)});
                    return;
                }
            }

            if (resumeInput.empty() || resumeDestination.empty()) {
                sendError(TDNSString(id), @"Torrent is not loaded and resume data is missing");
                return;
            }
        }
        addTorrent(id, resumeInput, resumeDestination, true, contentRoot, filePaths, seedOnly);
    }

    void pauseTorrent(const std::string &id) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = torrents_.find(id);
            if (it == torrents_.end() || !it->second.handle.is_valid()) {
                auto pending = pendingAdds_.find(id);
                if (pending != pendingAdds_.end()) {
                    pending->second->pauseRequested = true;
                    sendEvent(@{@"type": @"paused", @"id": TDNSString(id)});
                }
                return;
            }
            it->second.pauseRequested = true;
            it->second.handle.pause();
        }
        requestResumeDataSave(id);
        sendEvent(@{@"type": @"paused", @"id": TDNSString(id)});
    }

    void cancelTorrent(const std::string &id, bool deleteData) {
        bool pendingCancel = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = torrents_.find(id);
            if (it == torrents_.end() || !it->second.handle.is_valid()) {
                auto pending = pendingAdds_.find(id);
                if (pending != pendingAdds_.end()) {
                    pending->second->cancelRequested = true;
                    pending->second->deleteData = deleteData && !pending->second->seedOnly;
                    pendingCancel = true;
                }
                if (!pendingCancel) { return; }
            } else {
                session_.remove_torrent(it->second.handle, deleteData && !it->second.seedOnly ? lt::session_handle::delete_files : lt::remove_flags_t{});
                torrents_.erase(it);
                peerDetailSubscriptions_.erase(id);
                resumeStore_.remove(id);
                std::remove(resumeDataPath(id).c_str());
                sendEvent(@{@"type": @"cancelled", @"id": TDNSString(id)});
            }
        }
        if (pendingCancel) {
            sendEvent(@{@"type": @"cancelled", @"id": TDNSString(id)});
            return;
        }
        refreshHashingThreadTuning();
    }

    void stopSeeding(const std::string &id) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = torrents_.find(id);
            if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
            it->second.stopRequested = true;
            it->second.pauseRequested = true;
            it->second.handle.pause();
        }
        requestResumeDataSave(id);
        sendEvent(@{@"type": @"seedingStopped", @"id": TDNSString(id)});
    }

    void forceStartTorrent(const std::string &id) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(id);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
        TorrentRecord &record = it->second;
        record.stopRequested = false;
        record.pauseRequested = false;
        record.shareRatioTriggered = false;
        record.resumeRejected = false;
        record.handle.unset_flags(lt::torrent_flags::auto_managed);
        record.handle.resume();
        record.handle.force_reannounce(0, -1, lt::torrent_handle::high_priority);
        record.handle.force_dht_announce();
        if (localPeerDiscoveryEnabled_) { record.handle.force_lsd_announce(); }
        sendEvent(@{@"type": @"resumed", @"id": TDNSString(id)});
    }

    void setQueuePosition(const std::string &id, bool top) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(id);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
        if (top) it->second.handle.queue_position_top();
        else it->second.handle.queue_position_bottom();
    }

    void moveQueuePosition(const std::string &id, bool up) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(id);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
        if (up) it->second.handle.queue_position_up();
        else it->second.handle.queue_position_down();
    }

    void forceRecheckTorrent(const std::string &id) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(id);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
        it->second.resumeRejected = false;
        // The app can reject a completion while the disk is still settling.
        // Rechecking must be able to confirm completion a second time.
        it->second.doneEmitted = false;
        it->second.recheckPending = bool(it->second.handle.torrent_file());
        it->second.handle.force_recheck();
        if (!it->second.pauseRequested && !it->second.stopRequested) {
            it->second.handle.resume();
        }
    }

    void setSequentialDownload(const std::string &id, bool enabled) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(id);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
        if (enabled) it->second.handle.set_flags(lt::torrent_flags::sequential_download);
        else it->second.handle.unset_flags(lt::torrent_flags::sequential_download);
    }

    void applyFirstLastPiecePriorityLocked(TorrentRecord &record, bool enabled) {
        const auto info = record.handle.torrent_file();
        if (!info || info->num_pieces() <= 0) { return; }

        std::vector<lt::download_priority_t> filePriorities =
            record.configuredFilePriorities;
        if (filePriorities.size() != static_cast<std::size_t>(info->num_files())) {
            filePriorities = record.handle.get_file_priorities();
            if (filePriorities.size() != static_cast<std::size_t>(info->num_files())) {
                filePriorities.assign(static_cast<std::size_t>(info->num_files()),
                                      lt::default_priority);
            }
            record.configuredFilePriorities = filePriorities;
        }

        if (!enabled) {
            // File-priority changes are asynchronous in libtorrent. Reapplying
            // the tracked priorities removes our edge-piece overrides and
            // preserves the user's selected/deselected files.
            record.handle.prioritize_files(filePriorities);
            return;
        }

        // Keep file selection authoritative while giving playable files a
        // useful edge-piece boost. The old implementation only boosted the
        // torrent's global first/last pieces, which is almost never the first
        // or last piece of each file in a multi-file torrent. qBittorrent's
        // equivalent mode boosts up to roughly 1% of every selected file's
        // edge, which is much more useful for starting media or inspecting a
        // partially downloaded file.
        auto piecePriorities = record.handle.get_piece_priorities();
        const auto &files = info->layout();
        const int pieceLength = std::max(info->piece_length(), 1);
        for (int fileIndex = 0; fileIndex < info->num_files(); ++fileIndex) {
            const lt::file_index_t file(fileIndex);
            if (files.pad_file_at(file)
                || filePriorities[static_cast<std::size_t>(fileIndex)] == lt::dont_download) {
                continue;
            }

            const std::int64_t fileSize = files.file_size(file);
            if (fileSize <= 0) { continue; }

            const lt::piece_index_t firstPiece = info->map_file(file, 0, 1).piece;
            const lt::piece_index_t lastPiece = info->map_file(file, fileSize - 1, 1).piece;
            const std::int64_t edgeBytes = std::max<std::int64_t>(1, (fileSize + 99) / 100);
            const std::int64_t edgePieces = std::max<std::int64_t>(
                1, (edgeBytes + pieceLength - 1) / pieceLength);

            for (std::int64_t offset = 0; offset < edgePieces; ++offset) {
                const auto delta = lt::piece_index_t::diff_type(
                    static_cast<std::int32_t>(offset));
                const lt::piece_index_t frontPiece = firstPiece + delta;
                const lt::piece_index_t backPiece = lastPiece - delta;
                const int frontIndex = static_cast<int>(frontPiece);
                const int backIndex = static_cast<int>(backPiece);
                if (frontPiece <= lastPiece
                    && frontIndex >= 0
                    && frontIndex < static_cast<int>(piecePriorities.size())) {
                    piecePriorities[static_cast<std::size_t>(frontIndex)] = lt::top_priority;
                }
                if (backPiece >= firstPiece
                    && backIndex >= 0
                    && backIndex < static_cast<int>(piecePriorities.size())) {
                    piecePriorities[static_cast<std::size_t>(backIndex)] = lt::top_priority;
                }
            }
        }
        record.handle.prioritize_pieces(std::move(piecePriorities));
    }

    void setFileSelection(const std::string &torrentID, ::id selectedValue) {
        if (![selectedValue isKindOfClass:[NSArray class]]) { return; }
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(torrentID);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
        const auto info = it->second.handle.torrent_file();
        if (!info) { return; }
        std::unordered_set<int> selected;
        for (::id value in (NSArray *)selectedValue) {
            if ([value respondsToSelector:@selector(intValue)]) selected.insert([value intValue]);
        }
        std::vector<lt::download_priority_t> priorities(
            static_cast<std::size_t>(info->num_files()), lt::dont_download);
        for (int index : selected) {
            if (index >= 0 && index < info->num_files()) {
                priorities[static_cast<std::size_t>(index)] = lt::default_priority;
            }
        }
        it->second.configuredFilePriorities = priorities;
        it->second.handle.prioritize_files(priorities);
        if (it->second.firstLastPiecePriority) {
            applyFirstLastPiecePriorityLocked(it->second, true);
        }
    }

    void setFilePriority(const std::string &torrentID, int index, int priority) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(torrentID);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
        const auto info = it->second.handle.torrent_file();
        if (!info || index < 0 || index >= info->num_files()) { return; }
        if (it->second.configuredFilePriorities.size()
            != static_cast<std::size_t>(info->num_files())) {
            it->second.configuredFilePriorities = it->second.handle.get_file_priorities();
            if (it->second.configuredFilePriorities.size()
                != static_cast<std::size_t>(info->num_files())) {
                it->second.configuredFilePriorities.assign(
                    static_cast<std::size_t>(info->num_files()), lt::default_priority);
            }
        }
        const int clampedPriority = std::clamp(priority, 0, 7);
        it->second.configuredFilePriorities[static_cast<std::size_t>(index)] =
            lt::download_priority_t(clampedPriority);
        it->second.handle.file_priority(lt::file_index_t(index),
                                        lt::download_priority_t(clampedPriority));
        if (it->second.firstLastPiecePriority) {
            applyFirstLastPiecePriorityLocked(it->second, true);
        }
    }

    void setFirstLastPiecePriority(const std::string &torrentID, bool enabled) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(torrentID);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
        it->second.firstLastPiecePriority = enabled;
        applyFirstLastPiecePriorityLocked(it->second, enabled);
    }

    void setTorrentLimits(const std::string &torrentID,
                          int downloadLimit,
                          int uploadLimit,
                          int maxUploads) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(torrentID);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
        it->second.handle.set_download_limit(std::max(downloadLimit, 0));
        it->second.handle.set_upload_limit(std::max(uploadLimit, 0));
        it->second.handle.set_max_uploads(std::max(maxUploads, 0));
    }

    void setShareRatioPolicy(const std::string &torrentID,
                             double limit,
                             int action, int seedingMinutes, int inactiveMinutes,
                             std::int64_t seedingSeconds, std::int64_t inactiveSeconds) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(torrentID);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
        it->second.shareRatioLimit = std::isfinite(limit) && limit > 0.0 ? limit : 0.0;
        it->second.shareRatioAction = action == 1 || action == 2 ? action : 0;
        it->second.seedingTimeLimitSeconds = std::int64_t(seedingMinutes) * 60;
        it->second.inactiveSeedingTimeLimitSeconds = std::int64_t(inactiveMinutes) * 60;
        if (!it->second.seedingClockRestored) {
            it->second.seedingClock.seconds = std::max(it->second.seedingClock.seconds, seedingSeconds);
            it->second.seedingClock.inactiveSeconds = std::max(it->second.seedingClock.inactiveSeconds, inactiveSeconds);
            it->second.seedingClockRestored = true;
        }
        it->second.shareRatioTriggered = false;
    }
