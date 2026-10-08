#include "TorrentPeerSources.hpp"
#include <cassert>
#include <iostream>

int main() {
    namespace lt = libtorrent;
    lt::peer_info peer{};
    const lt::tcp::endpoint endpoint(boost::asio::ip::make_address("127.0.0.1"), 59001);
    peer.set_endpoints({}, endpoint);
    peer.connection_type = lt::peer_info::standard_bittorrent;
    peer.flags = lt::peer_info::outgoing_connection;
    assert(TDPeerSources(peer, {}) == std::vector<std::string>{"Source unavailable"});
    assert(TDPeerSources(peer, {endpoint}) == std::vector<std::string>{"Manual"});
    // The same address at a different port is a different peer.
    assert(TDPeerSources(peer, {{endpoint.address(), 59002}})
           == std::vector<std::string>{"Source unavailable"});

    peer.source = lt::peer_info::tracker | lt::peer_info::dht | lt::peer_info::pex
        | lt::peer_info::lsd | lt::peer_info::resume_data | lt::peer_info::incoming;
    const std::vector<std::string> combined{
        "Tracker", "DHT", "PeX", "LSD", "Resume", "Incoming", "Manual"};
    assert(TDPeerSources(peer, {endpoint}) == combined);
    peer.source = {};
    peer.flags = {};
    assert(TDPeerSources(peer, {}) == std::vector<std::string>{"Incoming"});

    // Web seed connections do not need a BitTorrent discovery flag.
    for (const auto type : {lt::peer_info::web_seed, lt::peer_info::http_seed}) {
        peer.connection_type = type;
        assert(TDPeerSources(peer, {endpoint}) == std::vector<std::string>{"Web seed"});
    }

    peer.connection_type = lt::peer_info::standard_bittorrent;
    peer.flags = lt::peer_info::outgoing_connection;
    const lt::tcp::endpoint ipv6(boost::asio::ip::make_address("2001:db8::1"), 59001);
    peer.set_endpoints({}, ipv6);
    assert(TDPeerSources(peer, {ipv6}) == std::vector<std::string>{"Manual"});
    assert(TDPeerSources(peer, {endpoint}) == std::vector<std::string>{"Source unavailable"});
    std::cout << "Peer source provenance checks passed\n";
}
