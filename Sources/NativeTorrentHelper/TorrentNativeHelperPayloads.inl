// Event payload construction for Helper.

    NSDictionary *addedPayload(const TorrentRecord &record,
                               const lt::torrent_status &status,
                               const lt::torrent_info &info) {
        NSMutableArray *files = [NSMutableArray array];
        const lt::file_storage &storage = info.layout();
        const auto renames = record.handle.get_renamed_files();
        for (int idx = 0; idx < storage.num_files(); ++idx) {
            const auto fileIndex = lt::file_index_t{idx};
            [files addObject:@{
                @"name": TDNSString(renames.file_path(storage, fileIndex)),
                @"length": @(storage.file_size(fileIndex)),
                @"isPadding": @(storage.pad_file_at(fileIndex))
            }];
        }

        NSData *metadataData = [NSData data];
        try {
            // Serialize the already-parsed info dictionary through the supported
            // libtorrent API.  The create_torrent(torrent_info) constructor is
            // deprecated and only existed as a convenience wrapper around this
            // operation.
            lt::add_torrent_params torrentParams;
            torrentParams.ti = std::make_shared<lt::torrent_info>(info);
            std::vector<char> encoded = lt::write_torrent_file_buf(
                torrentParams, lt::write_flags::allow_missing_piece_layer);
            metadataData = [NSData dataWithBytes:encoded.data() length:encoded.size()];
        } catch (...) {
            metadataData = nil;
        }

        NSString *metainfo = metadataData != nil ? [metadataData base64EncodedStringWithOptions:0] : (NSString *)nil;
        const int connectedSeeders = std::max(status.num_seeds, 0);
        const int connectedLeechers = std::max(status.num_peers - connectedSeeders, 0);
        const int connectablePeers = std::max(status.connect_candidates, 0);
        const int knownSeeders = std::max(status.list_seeds, connectedSeeders);
        const int knownPeers = std::max(status.list_peers, 0);
        const int knownLeechers = std::max(knownPeers - knownSeeders, connectedLeechers);

        std::int64_t contentBytes = 0;
        for (auto file : storage.file_range()) {
            if (!storage.pad_file_at(file)) contentBytes += storage.file_size(file);
        }
        NSMutableDictionary *payload = [@{
            @"type": @"added",
            @"id": TDNSString(record.id),
            @"name": TDNSString(info.name()),
            @"infoHash": TDNSString(TDInfoHashString(info)),
            @"path": TDNSString(status.save_path),
            @"length": @(contentBytes),
            @"files": files,
            @"connectablePeers": @(connectablePeers),
            @"connectedSeeders": @(connectedSeeders),
            @"connectedLeechers": @(connectedLeechers),
            @"knownPeers": @(knownPeers),
            @"knownSeeders": @(knownSeeders),
            @"knownLeechers": @(knownLeechers)
        } mutableCopy];

        if (status.num_complete >= 0) {
            payload[@"swarmSeeders"] = @(status.num_complete);
        }
        if (status.num_incomplete >= 0) {
            payload[@"swarmLeechers"] = @(status.num_incomplete);
        }
        if (metainfo != nil) {
            payload[@"metainfo"] = metainfo;
        }
        return payload;
    }

    NSDictionary *progressPayload(const TorrentRecord &record,
                                  const lt::torrent_status &status) {
        const int connectedSeeders = std::max(status.num_seeds, 0);
        const int connectedLeechers = std::max(status.num_peers - connectedSeeders, 0);
        const int connectablePeers = std::max(status.connect_candidates, 0);
        const int knownSeeders = std::max(status.list_seeds, connectedSeeders);
        const int knownPeers = std::max(status.list_peers, 0);
        const int knownLeechers = std::max(knownPeers - knownSeeders, connectedLeechers);
        // Checking progress is not the verified amount downloaded. Let the
        // app retain its saved totals until metadata/resume validation finishes.
        const bool completionReadable = !status.is_finished || record.seedOnly || record.completionFlushed;
        const bool progressReady = completionReadable && !record.recheckPending && status.has_metadata
            && status.state != lt::torrent_status::checking_resume_data
            && status.state != lt::torrent_status::checking_files
            && status.state != lt::torrent_status::downloading_metadata;
        const double progress = std::clamp(double(status.progress_ppm) / 1000000.0, 0.0, 1.0);
        NSNumber *remaining = nil;
        if (!status.is_finished && status.download_rate > 0 && status.total_wanted > status.total_wanted_done) {
            const double seconds = double(status.total_wanted - status.total_wanted_done) / double(status.download_rate);
            remaining = @(seconds * 1000.0);
        }

        // `torrent_status` exposes the rate-limiter queue, while the
        // outstanding piece queue carries the disk-facing backlog. Sample
        // both so the UI/diagnostics can tell a slow disk from a peer-starved
        // torrent without changing libtorrent's scheduling decisions.
        std::int64_t diskBacklogBytes = 0;
        try {
            std::vector<lt::partial_piece_info> queue;
            record.handle.get_download_queue(queue);
            for (const auto &piece : queue) {
                if (piece.blocks == nullptr || piece.blocks_in_piece <= 0) { continue; }
                for (int blockIndex = 0; blockIndex < piece.blocks_in_piece; ++blockIndex) {
                    const auto &block = piece.blocks[blockIndex];
                    if (block.state == lt::block_info::requested
                        || block.state == lt::block_info::writing) {
                        diskBacklogBytes += static_cast<std::int64_t>(block.block_size);
                    }
                }
            }
        } catch (...) {
            // Telemetry must never make a progress update fail.
        }

        NSMutableDictionary *payload = [@{
            @"type": @"progress",
            @"id": TDNSString(record.id),
            @"progress": @(progress),
            @"isProgressReady": @(progressReady),
            @"isFinished": @(progressReady && status.is_finished),
            @"downloadSpeed": @(status.download_rate),
            @"uploadSpeed": @(status.upload_rate),
            @"downloaded": @(status.total_wanted_done),
            @"uploaded": @(status.all_time_upload),
            @"seedingTimeSeconds": @(record.seedingClock.seconds),
            @"inactiveSeedingTimeSeconds": @(record.seedingClock.inactiveSeconds),
            @"isQueued": @(bool(status.flags & lt::torrent_flags::auto_managed)
                            && bool(status.flags & lt::torrent_flags::paused)
                            && !record.pauseRequested),
            @"numPeers": @(status.num_peers),
            @"connectablePeers": @(connectablePeers),
            @"connectedSeeders": @(connectedSeeders),
            @"connectedLeechers": @(connectedLeechers),
            @"knownPeers": @(knownPeers),
            @"knownSeeders": @(knownSeeders),
            @"knownLeechers": @(knownLeechers),
            @"diskBacklogBytes": @(std::max<std::int64_t>(diskBacklogBytes, 0)),
            @"diskQueueLimitBytes": @(std::max(record.adaptiveDiskQueueBytes, 0)),
            @"diskQueueWarnings": @(std::max(record.diskLimitWarnings, 0)),
            @"requestQueueLimit": @(adaptiveRequestQueue_),
            @"requestQueueWarnings": @(record.requestLimitWarnings),
            @"schedulerRank": @(record.schedulerRank),
            @"path": TDNSString(status.save_path)
        } mutableCopy];

        if (status.num_complete >= 0) {
            payload[@"swarmSeeders"] = @(status.num_complete);
        }
        if (status.num_incomplete >= 0) {
            payload[@"swarmLeechers"] = @(status.num_incomplete);
        }
        if (remaining != nil) {
            payload[@"timeRemaining"] = remaining;
        }
        return payload;
    }

    NSDictionary *peerPayload(const TorrentRecord &record,
                              const lt::torrent_status &status) {
        std::vector<lt::peer_info> peerInfo;
        try {
            record.handle.get_peer_info(peerInfo);
        } catch (...) {
            peerInfo.clear();
        }

        const int connectedPeerLimit = std::max(status.num_peers, 0);
        int emittedConnectedPeers = 0;
        NSMutableArray *peers = [NSMutableArray arrayWithCapacity:peerInfo.size()];
        for (const auto &peer : peerInfo) {
            // get_peer_info() also returns half-open connections while a
            // socket is connecting or waiting for the BitTorrent handshake.
            // They are not included in torrent_status::num_peers, so omit
            // them here to keep the inspector's connected count consistent
            // with the download row.
            if (bool(peer.flags & lt::peer_info::connecting)
                || bool(peer.flags & lt::peer_info::handshake)) {
                continue;
            }
            // libtorrent's peer list can briefly contain a fully-described
            // candidate while torrent_status still reports zero established
            // connections. The status count is the authoritative value used
            // by the download row, so keep both surfaces in lockstep.
            if (emittedConnectedPeers >= connectedPeerLimit) {
                continue;
            }
            NSMutableArray *sources = [NSMutableArray array];
            for (const auto &source : TDPeerSources(peer, record.manuallyAddedPeers)) {
                [sources addObject:TDNSString(source)];
            }

            const auto endpoint = peer.remote_endpoint();
            const std::string address = endpoint.address().to_string();
            const bool outgoing = bool(peer.flags & lt::peer_info::outgoing_connection);
            const bool isUTP = bool(peer.flags & lt::peer_info::utp_socket);
            const bool isI2P = bool(peer.flags & lt::peer_info::i2p_socket);
            const char *transport = isI2P ? "I2P" : (isUTP ? "µTP" : "TCP");
            const double peerProgress = std::clamp(
                double(peer.progress_ppm) / 1'000'000.0, 0.0, 1.0);

            [peers addObject:@{
                @"address": TDNSString(address),
                @"port": @(endpoint.port()),
                @"client": TDNSString(peer.client.empty() ? std::string("Unknown client") : peer.client),
                @"transport": TDNSString(std::string(transport)),
                @"direction": outgoing ? @"Outgoing" : @"Incoming",
                @"sources": sources,
                @"downloadSpeed": @(std::max(peer.payload_down_speed, 0)),
                @"uploadSpeed": @(std::max(peer.payload_up_speed, 0)),
                @"requestQueueLength": @(peer.download_queue_length),
                @"targetRequestQueueLength": @(peer.target_dl_queue_length),
                @"remoteChoked": @(bool(peer.flags & lt::peer_info::remote_choked)),
                @"progress": @(peerProgress),
                @"isSeed": @(bool(peer.flags & lt::peer_info::seed))
            }];
            ++emittedConnectedPeers;
        }

        return @{
            @"type": @"peers",
            @"id": TDNSString(record.id),
            @"availability": @(std::max(double(status.distributed_copies), 0.0)),
            @"peers": peers
        };
    }

    NSDictionary *donePayload(const TorrentRecord &record,
                              const lt::torrent_status &status,
                              const lt::torrent_info &info) {
        NSMutableArray *files = [NSMutableArray array];
        const lt::file_storage &storage = info.layout();
        const auto renames = record.handle.get_renamed_files();
        for (int idx = 0; idx < storage.num_files(); ++idx) {
            const auto fileIndex = lt::file_index_t{idx};
            [files addObject:@{
                @"name": TDNSString(renames.file_path(storage, fileIndex)),
                @"length": @(storage.file_size(fileIndex)),
                @"isPadding": @(storage.pad_file_at(fileIndex))
            }];
        }

        return @{
            @"type": @"done",
            @"id": TDNSString(record.id),
            @"path": TDNSString(status.save_path),
            @"files": files
        };
    }
