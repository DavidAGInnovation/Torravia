#pragma once

#include "libtorrent/settings_pack.hpp"
#include "libtorrent/alert.hpp"

// A peer connection snapshots this local default in libtorrent 2.1. A later
// session setting does not update it, so supply sufficient pipeline headroom
// before connecting (about 47 MiB of requested payload at 16 KiB per block). The
// engine still honors an advertised remote BEP 10 reqq capacity. Request entries
// are small bookkeeping objects; receive/disk buffers have separate bounds.
static constexpr int TDNormalOutboundRequestQueue = 3'000;
static constexpr int TDNormalInboundRequestQueue = 2'000;
static constexpr int TDAggressiveInboundRequestQueue = 4'000;

    // Keep discovery conservative while transfers are healthy. The helper
    // temporarily switches these values to the aggressive profile when a
    // torrent is under-connected or stalled (see maintainPeerDiscovery()).
    static void TDApplyDiscoverySettings(libtorrent::settings_pack &pack,
                                         bool aggressive) {
        if (aggressive) {
            pack.set_bool(libtorrent::settings_pack::dht_aggressive_lookups, true);
            pack.set_int(libtorrent::settings_pack::dht_search_branching, 8);
            pack.set_int(libtorrent::settings_pack::dht_max_peers_reply, 500);
            pack.set_int(libtorrent::settings_pack::dht_announce_interval, 60);
            pack.set_int(libtorrent::settings_pack::dht_max_peers, 1'000);
            pack.set_int(libtorrent::settings_pack::local_service_announce_interval, 30);
            pack.set_bool(libtorrent::settings_pack::announce_to_all_trackers, true);
            pack.set_bool(libtorrent::settings_pack::announce_to_all_tiers, true);
            pack.set_int(libtorrent::settings_pack::tracker_backoff, 75);
            pack.set_int(libtorrent::settings_pack::peer_turnover, 15);
            pack.set_int(libtorrent::settings_pack::peer_turnover_cutoff, 80);
            pack.set_int(libtorrent::settings_pack::peer_turnover_interval, 60);
            pack.set_int(libtorrent::settings_pack::connection_speed, 100);
            pack.set_int(libtorrent::settings_pack::torrent_connect_boost, 50);
            // Recovery should find more peers without abandoning slower
            // connection setups earlier than the normal desktop profile.
            pack.set_int(libtorrent::settings_pack::peer_connect_timeout, 15);
            pack.set_int(libtorrent::settings_pack::max_peerlist_size, 20'000);
            pack.set_int(libtorrent::settings_pack::max_paused_peerlist_size, 20'000);
            pack.set_int(libtorrent::settings_pack::request_queue_time, 8);
            return;
        }

        // These values match libtorrent's normal desktop-oriented behavior
        // closely enough to avoid needless DHT/tracker traffic and peer churn
        // while a transfer already has a healthy working set.
        pack.set_bool(libtorrent::settings_pack::dht_aggressive_lookups, false);
        pack.set_int(libtorrent::settings_pack::dht_search_branching, 5);
        pack.set_int(libtorrent::settings_pack::dht_max_peers_reply, 100);
        pack.set_int(libtorrent::settings_pack::dht_announce_interval, 15 * 60);
        pack.set_int(libtorrent::settings_pack::dht_max_peers, 500);
        pack.set_int(libtorrent::settings_pack::local_service_announce_interval, 5 * 60);
        pack.set_bool(libtorrent::settings_pack::announce_to_all_trackers, false);
        // Query one tracker from every tier in the normal profile. This keeps
        // multi-tier torrents discoverable without announcing to every tracker
        // in a tier at the same time.
        pack.set_bool(libtorrent::settings_pack::announce_to_all_tiers, true);
        pack.set_int(libtorrent::settings_pack::tracker_backoff, 250);
        pack.set_int(libtorrent::settings_pack::peer_turnover, 4);
        pack.set_int(libtorrent::settings_pack::peer_turnover_cutoff, 90);
        pack.set_int(libtorrent::settings_pack::peer_turnover_interval, 5 * 60);
        pack.set_int(libtorrent::settings_pack::connection_speed, 30);
        pack.set_int(libtorrent::settings_pack::torrent_connect_boost, 30);
        pack.set_int(libtorrent::settings_pack::peer_connect_timeout, 15);
        pack.set_int(libtorrent::settings_pack::max_peerlist_size, 10'000);
        pack.set_int(libtorrent::settings_pack::max_paused_peerlist_size, 10'000);
        pack.set_int(libtorrent::settings_pack::request_queue_time, 5);
    }

    static libtorrent::settings_pack TDMakeSessionSettings() {
        libtorrent::settings_pack pack;
        pack.set_bool(libtorrent::settings_pack::enable_dht, true);
        // Keep DHT active alongside trackers so outgoing discovery still
        // works when a tracker is stale or unreachable.
        pack.set_bool(libtorrent::settings_pack::use_dht_as_fallback, false);
        // Seed the routing table with several independent bootstrap services
        // so a fresh session can reach the wider DHT without waiting for a
        // tracker response.
        pack.set_str(libtorrent::settings_pack::dht_bootstrap_nodes,
                     "dht.libtorrent.org:25401,dht.transmissionbt.com:6881,router.bittorrent.com:6881,router.utorrent.com:6881,router.bt.ouinet.work:6881");
        pack.set_bool(libtorrent::settings_pack::dht_extended_routing_table, true);
        pack.set_bool(libtorrent::settings_pack::enable_lsd, true);
        // Accept inbound peers and request automatic port mappings so that
        // torrents can discover more peers when the network/router allows it.
        // Mapping failures are non-fatal; outgoing tracker/DHT connections
        // continue to work without UPnP or NAT-PMP support.
        pack.set_bool(libtorrent::settings_pack::enable_upnp, true);
        pack.set_bool(libtorrent::settings_pack::enable_natpmp, true);
        pack.set_bool(libtorrent::settings_pack::enable_incoming_tcp, true);
        pack.set_bool(libtorrent::settings_pack::enable_incoming_utp, true);
        pack.set_bool(libtorrent::settings_pack::enable_outgoing_tcp, true);
        pack.set_bool(libtorrent::settings_pack::enable_outgoing_utp, true);
        // If the preferred listening port is occupied, let libtorrent retry
        // with an OS-selected port instead of leaving the session without an
        // inbound socket. The listen_succeeded alert reports the actual port.
        pack.set_bool(libtorrent::settings_pack::listen_system_port_fallback, true);
        // Start with a useful number of peer slots and grow it gradually when
        // the active swarms actually need more connections. This avoids the
        // latency/CPU cost of opening hundreds of sockets for every torrent.
        pack.set_int(libtorrent::settings_pack::connections_limit, 500);
        pack.set_int(libtorrent::settings_pack::connections_slack, 10);
        pack.set_int(libtorrent::settings_pack::listen_queue_size, 128);
        // Use a desktop-oriented I/O baseline. A larger queued-disk budget
        // avoids back-pressure on fast peers while
        // storage catches up, especially when several pieces arrive at once.
        pack.set_int(libtorrent::settings_pack::aio_threads, 10);
        // Hash checks are generally sequential on HDDs; one worker avoids
        // turning verification into random I/O and keeps the default safe for
        // laptops and external drives. The helper raises this only after it
        // confirms that every known destination is solid-state storage.
        pack.set_int(libtorrent::settings_pack::hashing_threads, 1);
        // Start with qBittorrent-like per-peer buffers. The helper can grow
        // these after it observes a real working set of peers, subject to the
        // process memory budget in applyAdaptiveSessionSettings().
        pack.set_int(libtorrent::settings_pack::max_peer_recv_buffer_size, 2 * 1024 * 1024);
        pack.set_int(libtorrent::settings_pack::recv_socket_buffer_size, 2 * 1024 * 1024);
        pack.set_int(libtorrent::settings_pack::send_socket_buffer_size, 2 * 1024 * 1024);
        pack.set_int(libtorrent::settings_pack::send_buffer_watermark, 2 * 1024 * 1024);
        pack.set_int(libtorrent::settings_pack::send_buffer_watermark_factor, 150);
        pack.set_int(libtorrent::settings_pack::predictive_piece_announce, 250);
        // Keep enough headroom for status/tracker alerts when many torrents
        // are active. The dropped-alert diagnostic below still reports if the
        // process ever exhausts this bounded queue.
        // Alert processing is event-driven, but keep a generous bounded queue
        // for bursts while many torrents are being restored or reannounced.
        pack.set_int(libtorrent::settings_pack::alert_queue_size, 200'000);
        // Keep a modest descriptor cache without making large torrents hit
        // the process/file-system descriptor limits by default.
        pack.set_int(libtorrent::settings_pack::file_pool_size, 100);
        pack.set_int(libtorrent::settings_pack::unchoke_slots_limit, 20);
        pack.set_int(libtorrent::settings_pack::mixed_mode_algorithm, libtorrent::settings_pack::prefer_tcp);
        pack.set_int(libtorrent::settings_pack::active_downloads, -1);
        pack.set_int(libtorrent::settings_pack::active_seeds, -1);
        pack.set_int(libtorrent::settings_pack::active_limit, -1);
        pack.set_int(libtorrent::settings_pack::active_tracker_limit, -1);
        pack.set_int(libtorrent::settings_pack::active_dht_limit, -1);
        pack.set_int(libtorrent::settings_pack::active_lsd_limit, -1);
        pack.set_bool(libtorrent::settings_pack::prefer_udp_trackers, true);
        // Keep a failed tracker eligible for later recovery. Public trackers
        // often have short DNS/UDP outages; keep these sources around instead
        // of dropping them after the first few failed tries.
        pack.set_int(libtorrent::settings_pack::max_failcount, 10);
        // Discovery changes must not overwrite adaptive transfer budgets.
        // Set these once at startup; applyAdaptiveSessionSettings owns all
        // subsequent updates, including recovery-profile floors.
        pack.set_int(libtorrent::settings_pack::max_queued_disk_bytes, 256 * 1024 * 1024);
        pack.set_int(libtorrent::settings_pack::max_out_request_queue, TDNormalOutboundRequestQueue);
        pack.set_int(libtorrent::settings_pack::max_allowed_in_request_queue, TDNormalInboundRequestQueue);
        // Apply the conservative baseline after the static session settings;
        // recovery can switch the same profile to the high-fanout values.
        TDApplyDiscoverySettings(pack, false);
        pack.set_int(libtorrent::settings_pack::alert_mask,
                     libtorrent::alert_category::error |
                     libtorrent::alert_category::port_mapping |
                     libtorrent::alert_category::tracker |
                     libtorrent::alert_category::peer |
                     libtorrent::alert_category::connect |
                     libtorrent::alert_category::status |
                     libtorrent::alert_category::storage |
                     libtorrent::alert_category::performance_warning);
        return pack;
    }
