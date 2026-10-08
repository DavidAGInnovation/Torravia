#pragma once

#include "libtorrent/announce_entry.hpp"
#include "libtorrent/info_hash.hpp"

// A tracker announces through multiple listen sockets, and hybrid torrents
// also use two info hashes. One failed route must not mask a working route.
static const libtorrent::announce_infohash *TDTrackerStatus(
    const libtorrent::announce_entry &entry,
    const libtorrent::info_hash_t &hashes) {
    const libtorrent::announce_infohash *selected = nullptr;
    int selectedRank = -1;
    for (const auto &endpoint : entry.endpoints) {
        if (!endpoint.enabled) { continue; }
        for (auto protocol : {libtorrent::protocol_version::V1,
                              libtorrent::protocol_version::V2}) {
            if (protocol == libtorrent::protocol_version::V1 && !hashes.has_v1()) { continue; }
            if (protocol == libtorrent::protocol_version::V2 && !hashes.has_v2()) { continue; }
            const auto &status = endpoint.info_hashes[protocol];
            const bool working = status.start_sent && !status.last_error;
            const int rank = working ? 3 : status.updating ? 2 : !status.last_error ? 1 : 0;
            if (rank > selectedRank) {
                selected = &status;
                selectedRank = rank;
            }
        }
    }
    return selected;
}
