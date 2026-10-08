// Torrent discovery, inspection, and peer-management operations for Helper.

    void reannounceTorrent(const std::string &id) {
        lt::torrent_handle handle;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = torrents_.find(id);
            if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
            handle = it->second.handle;
        }
        try {
            handle.force_reannounce(0, -1, lt::torrent_handle::high_priority);
            if (dhtEnabled_) { handle.force_dht_announce(); }
            if (localPeerDiscoveryEnabled_) { handle.force_lsd_announce(); }
        } catch (const std::exception &ex) {
            sendError(TDNSString(id), TDNSString(ex.what()));
        }
    }

    void addTracker(const std::string &id, const std::string &url, int tier) {
        if (!TDHasSupportedScheme(url, {"udp", "http", "https"})) {
            sendError(TDNSString(id), @"Tracker URL must use udp, http, or https.");
            return;
        }
        lt::torrent_handle handle;
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = torrents_.find(id);
            if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
            lt::announce_entry entry(url);
            entry.tier = std::max(tier, 0);
            it->second.handle.add_tracker(entry);
            handle = it->second.handle;
        } catch (const std::exception &ex) {
            sendError(TDNSString(id), TDNSString(ex.what()));
            return;
        }
        try {
            handle.force_reannounce(0, url, lt::torrent_handle::high_priority);
        } catch (const std::exception &ex) {
            sendError(TDNSString(id), TDNSString(ex.what()));
        }
    }

    void removeTracker(const std::string &id, const std::string &url) {
        if (url.empty()) { return; }
        lt::torrent_handle handle;
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = torrents_.find(id);
            if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
            auto trackers = it->second.handle.trackers();
            trackers.erase(std::remove_if(trackers.begin(), trackers.end(), [&](const lt::announce_entry &entry) {
                return entry.url == url;
            }), trackers.end());
            it->second.handle.replace_trackers(std::move(trackers));
            handle = it->second.handle;
        } catch (const std::exception &ex) {
            sendError(TDNSString(id), TDNSString(ex.what()));
            return;
        }
        try {
            handle.force_reannounce(0, -1, lt::torrent_handle::high_priority);
        } catch (const std::exception &ex) {
            sendError(TDNSString(id), TDNSString(ex.what()));
        }
    }

    // Keep failed trackers in the announce list. libtorrent already applies
    // tracker backoff; this wrapper adds a longer cooldown for manual refresh
    // decisions without destroying a useful source after one transient error.
    void noteTrackerFailure(const std::string &id,
                            const std::string &url,
                            int consecutiveFailures) {
        if (url.empty()) { return; }
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(id);
        if (it == torrents_.end()) { return; }
        auto &health = it->second.trackerHealth[TDLowercase(url)];
        health.failures += 1;
        health.consecutiveFailures = std::max(
            health.consecutiveFailures, std::max(consecutiveFailures, 1));
        const int exponent = std::min(health.consecutiveFailures - 1, 5);
        const int delay = std::min(30 * (1 << exponent), 900);
        health.cooldownUntil = std::chrono::steady_clock::now()
            + std::chrono::seconds(delay);
    }

    void addWebSeed(const std::string &id, const std::string &url) {
        if (!TDHasSupportedScheme(url, {"http", "https"})) {
            sendError(TDNSString(id), @"Web seed URL must use http or https.");
            return;
        }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = torrents_.find(id);
            if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
            it->second.handle.add_url_seed(url);
        } catch (const std::exception &ex) {
            sendError(TDNSString(id), TDNSString(ex.what()));
        }
    }

    void removeWebSeed(const std::string &id, const std::string &url) {
        if (url.empty()) { return; }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = torrents_.find(id);
            if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
            it->second.handle.remove_url_seed(url);
        } catch (const std::exception &ex) {
            sendError(TDNSString(id), TDNSString(ex.what()));
        }
    }

    void addPeer(const std::string &id, const std::string &addressText) {
        lt::tcp::endpoint endpoint;
        if (!TDParseEndpoint(addressText, endpoint)) {
            sendError(TDNSString(id), @"Peer address must be an IP:port endpoint.");
            return;
        }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = torrents_.find(id);
            if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
            it->second.handle.connect_peer(endpoint);
            auto &manualPeers = it->second.manuallyAddedPeers;
            if (std::find(manualPeers.begin(), manualPeers.end(), endpoint) == manualPeers.end()) {
                manualPeers.push_back(endpoint);
            }
        } catch (const std::exception &ex) {
            sendError(TDNSString(id), TDNSString(ex.what()));
        }
    }

    void sendDiscovery(const std::string &torrentID) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(torrentID);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }

        // Report the actual announce list, including failed trackers that
        // libtorrent will retry with backoff.
        const auto retainedTrackers = it->second.handle.trackers();
        const auto hashes = it->second.handle.info_hashes();

        NSMutableArray *trackers = [NSMutableArray array];
        for (const auto &entry : retainedTrackers) {
            const lt::announce_infohash *infohash = TDTrackerStatus(entry, hashes);
            std::string state = "waiting";
            std::string message;
            int fails = 0;
            int scrapeComplete = -1;
            int scrapeIncomplete = -1;
            bool updating = false;
            if (infohash != nullptr) {
                fails = infohash->fails;
                scrapeComplete = infohash->scrape_complete;
                scrapeIncomplete = infohash->scrape_incomplete;
                updating = infohash->updating;
                message = infohash->message;
                if (infohash->start_sent && !infohash->last_error) state = "working";
                else if (updating) state = "announcing";
                else if (!infohash->last_error) state = "waiting";
                else state = "error";
            }
            [trackers addObject:@{
                @"url": TDNSString(entry.url),
                @"tier": @(entry.tier),
                @"state": TDNSString(state),
                @"source": @(entry.source),
                @"fails": @(fails),
                @"updating": @(updating),
                @"message": TDNSString(message),
                @"scrapeComplete": @(scrapeComplete),
                @"scrapeIncomplete": @(scrapeIncomplete)
            }];
        }

        NSMutableArray *webSeeds = [NSMutableArray array];
        for (const auto &url : it->second.handle.url_seeds()) {
            [webSeeds addObject:TDNSString(url)];
        }
        sendEvent(@{@"type": @"discovery",
                    @"id": TDNSString(torrentID),
                    @"trackers": trackers,
                    @"webSeeds": webSeeds,
                    @"trackerPeers": @(it->second.trackerReplyPeers)});
    }

    void sendPieceAvailability(const std::string &torrentID) {
        lt::torrent_handle handle;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = torrents_.find(torrentID);
            if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
            handle = it->second.handle;
        }

        try {
            std::vector<int> availability;
            handle.piece_availability(availability);
            NSMutableArray *pieces = [NSMutableArray arrayWithCapacity:availability.size()];
            for (const int value : availability) {
                [pieces addObject:@(std::max(value, 0))];
            }
            sendEvent(@{
                @"type": @"pieceAvailability",
                @"id": TDNSString(torrentID),
                @"pieces": pieces
            });
        } catch (const std::exception &ex) {
            sendError(TDNSString(torrentID), TDNSString(ex.what()));
        }
    }

    void sendPieceInspection(const std::string &torrentID) {
        lt::torrent_handle handle;
        std::shared_ptr<const lt::torrent_info> info;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = torrents_.find(torrentID);
            if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
            handle = it->second.handle;
            info = it->second.torrentInfo;
            if (!info) {
                info = handle.torrent_file();
            }
        }
        if (!info) { return; }

        try {
            const lt::torrent_status status = handle.status(
                lt::torrent_handle::query_pieces | lt::torrent_handle::query_distributed_copies);
            std::vector<int> availability;
            handle.piece_availability(availability);
            const auto filePriorities = handle.get_file_priorities();
            const auto piecePriorities = handle.get_piece_priorities();
            const lt::file_storage &storage = info->layout();

            NSMutableArray *files = [NSMutableArray arrayWithCapacity:storage.num_files()];
            for (int idx = 0; idx < storage.num_files(); ++idx) {
                const lt::file_index_t fileIndex{idx};
                const std::int64_t length = storage.file_size(fileIndex);
                int firstPiece = -1;
                int lastPiece = -1;
                int pieceCount = 0;
                int haveCount = 0;
                double availabilityTotal = 0.0;
                if (length > 0 && info->num_pieces() > 0) {
                    const auto firstRequest = storage.map_file(fileIndex, 0, 1);
                    const auto lastRequest = storage.map_file(fileIndex, length - 1, 1);
                    firstPiece = static_cast<int>(firstRequest.piece);
                    lastPiece = static_cast<int>(lastRequest.piece);
                    pieceCount = std::max(lastPiece - firstPiece + 1, 0);
                    for (int piece = firstPiece; piece <= lastPiece; ++piece) {
                        const lt::piece_index_t pieceIndex{piece};
                        if (!status.pieces.empty() && piece < static_cast<int>(status.pieces.size()) && status.pieces[pieceIndex]) {
                            ++haveCount;
                        }
                        if (piece >= 0 && piece < static_cast<int>(availability.size())) {
                            availabilityTotal += availability[static_cast<std::size_t>(piece)];
                        }
                    }
                }
                const double progress = pieceCount > 0
                    ? static_cast<double>(haveCount) / static_cast<double>(pieceCount) : 1.0;
                const double fileAvailability = pieceCount > 0
                    ? availabilityTotal / static_cast<double>(pieceCount) : 0.0;
                const int priority = idx < static_cast<int>(filePriorities.size())
                    ? static_cast<int>(static_cast<std::uint8_t>(filePriorities[static_cast<std::size_t>(idx)])) : 4;
                [files addObject:@{
                    @"index": @(idx),
                    @"name": TDNSString(storage.file_path(fileIndex)),
                    @"length": @(length),
                    @"progress": @(progress),
                    @"availability": @(fileAvailability),
                    @"priority": @(priority),
                    @"pieceStart": @(firstPiece),
                    @"pieceEnd": @(lastPiece)
                }];
            }

            NSMutableArray *pieces = [NSMutableArray arrayWithCapacity:info->num_pieces()];
            for (int index = 0; index < info->num_pieces(); ++index) {
                NSString *hash = @"";
                if (info->v1()) {
                    const std::string rawHash = info->hash_for_piece(lt::piece_index_t(index)).to_string();
                    static constexpr char digits[] = "0123456789abcdef";
                    std::string encoded;
                    encoded.reserve(rawHash.size() * 2);
                    for (const unsigned char byte : rawHash) {
                        encoded.push_back(digits[byte >> 4]);
                        encoded.push_back(digits[byte & 0x0f]);
                    }
                    hash = TDNSString(encoded);
                }
                const lt::piece_index_t pieceIndex{index};
                const bool have = !status.pieces.empty()
                    && index < static_cast<int>(status.pieces.size()) && status.pieces[pieceIndex];
                const int available = index < static_cast<int>(availability.size())
                    ? availability[static_cast<std::size_t>(index)] : 0;
                const int priority = index < static_cast<int>(piecePriorities.size())
                    ? static_cast<int>(static_cast<std::uint8_t>(piecePriorities[static_cast<std::size_t>(index)])) : 4;
                [pieces addObject:@{
                    @"index": @(index),
                    @"have": @(have),
                    @"availability": @(std::max(available, 0)),
                    @"priority": @(priority),
                    @"hash": hash
                }];
            }
            sendEvent(@{
                @"type": @"pieceInspection",
                @"id": TDNSString(torrentID),
                @"pieceLength": @(info->piece_length()),
                @"files": files,
                @"pieces": pieces
            });
        } catch (const std::exception &ex) {
            sendError(TDNSString(torrentID), TDNSString(ex.what()));
        }
    }

    void banPeer(const std::string &id, const std::string &addressText) {
        lt::address address;
        if (!TDParseAddress(addressText, address)) { return; }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            bannedPeers_.insert(addressText);
        }
        lt::ip_filter filter = session_.get_ip_filter();
        filter.add_rule(address, address, lt::ip_filter::blocked);
        session_.set_ip_filter(std::move(filter));
    }

    void renameFile(const std::string &id, int index, const std::string &path) {
        if (path.empty() || path.find("..") != std::string::npos) { return; }
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = torrents_.find(id);
        if (it == torrents_.end() || !it->second.handle.is_valid()) { return; }
        const auto info = it->second.handle.torrent_file();
        if (!info || index < 0 || index >= info->num_files()) { return; }
        it->second.handle.rename_file(lt::file_index_t(index), path);
    }

    void setPeerDetailsEnabled(const std::string &id, bool enabled) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (enabled) {
                peerDetailSubscriptions_.insert(id);
            } else {
                peerDetailSubscriptions_.erase(id);
            }
        }
        // Publish the first snapshot immediately when inspection starts.
        // The regular polling loop continues to refresh it in the background.
        if (enabled) {
            pollPeerDetails(id);
        }
    }
