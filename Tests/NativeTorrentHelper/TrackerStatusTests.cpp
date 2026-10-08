#include "TorrentTrackerStatus.hpp"
#include <cassert>
#include <iostream>

int main() {
    namespace lt = libtorrent;
    lt::info_hash_t v1(lt::sha1_hash("01234567890123456789"));
    lt::announce_entry entry("udp://tracker.example:80/announce");
    entry.endpoints.resize(2);
    auto &failed = entry.endpoints[0].info_hashes[lt::protocol_version::V1];
    auto &working = entry.endpoints[1].info_hashes[lt::protocol_version::V1];
    failed.last_error = lt::error_code(1, lt::system_category());
    failed.fails = 2;
    working.start_sent = true;
    working.scrape_complete = 7;
    assert(TDTrackerStatus(entry, v1) == &working);

    // A successful route stays working while its next announce is pending.
    working.updating = true;
    assert(TDTrackerStatus(entry, v1) == &working);
    working.updating = false;
    entry.endpoints[1].enabled = false;
    assert(TDTrackerStatus(entry, v1) == &failed);

    // Do not use the unused v2 slot to hide a genuine v1 failure.
    entry.endpoints.resize(1);
    assert(TDTrackerStatus(entry, v1)->last_error);
    auto &v2 = entry.endpoints[0].info_hashes[lt::protocol_version::V2];
    v2.start_sent = true;
    lt::info_hash_t hybrid = v1;
    hybrid.v2 = lt::sha256_hash("01234567890123456789012345678901");
    assert(TDTrackerStatus(entry, hybrid) == &v2);
    entry.endpoints.clear();
    assert(TDTrackerStatus(entry, v1) == nullptr);
    std::cout << "Tracker status regression checks passed\n";
}
