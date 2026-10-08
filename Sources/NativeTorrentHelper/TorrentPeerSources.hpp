#pragma once

#include <algorithm>
#include <string>
#include <vector>
#include "libtorrent/peer_info.hpp"

// Manual connections have no libtorrent discovery flag. Keep their endpoints
// per torrent rather than treating every outgoing connection as manual.
static std::vector<std::string> TDPeerSources(
    const libtorrent::peer_info &peer,
    const std::vector<libtorrent::tcp::endpoint> &manualPeers) {
    namespace lt = libtorrent;
    std::vector<std::string> sources;
    if (bool(peer.source & lt::peer_info::tracker)) { sources.emplace_back("Tracker"); }
    if (bool(peer.source & lt::peer_info::dht)) { sources.emplace_back("DHT"); }
    if (bool(peer.source & lt::peer_info::pex)) { sources.emplace_back("PeX"); }
    if (bool(peer.source & lt::peer_info::lsd)) { sources.emplace_back("LSD"); }
    if (bool(peer.source & lt::peer_info::resume_data)) { sources.emplace_back("Resume"); }
    if (bool(peer.source & lt::peer_info::incoming)) { sources.emplace_back("Incoming"); }

    if (peer.connection_type == lt::peer_info::web_seed
        || peer.connection_type == lt::peer_info::http_seed) {
        sources.emplace_back("Web seed");
    } else if (std::find(manualPeers.begin(), manualPeers.end(), peer.remote_endpoint())
               != manualPeers.end()) {
        sources.emplace_back("Manual");
    }
    // An accepted connection is known to be incoming even when the engine
    // supplies no discovery flags. Its remote client's discovery is unknown.
    if (sources.empty() && !bool(peer.flags & lt::peer_info::outgoing_connection)) {
        sources.emplace_back("Incoming");
    }
    if (sources.empty()) { sources.emplace_back("Source unavailable"); }
    return sources;
}
