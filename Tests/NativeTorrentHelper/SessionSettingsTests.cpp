#include "TorrentSessionSettings.hpp"
#include <cassert>
#include <iostream>

int main() {
    namespace lt = libtorrent;
    auto pack = TDMakeSessionSettings();
    assert(pack.get_int(lt::settings_pack::max_out_request_queue) == 3'000);
    assert(pack.get_int(lt::settings_pack::peer_connect_timeout) == 15);
    assert(pack.get_int(lt::settings_pack::connection_speed) == 30);
    // Customized transfer budgets must survive both discovery transitions.
    pack.set_int(lt::settings_pack::max_out_request_queue, 2'000);
    pack.set_int(lt::settings_pack::max_allowed_in_request_queue, 4'000);
    pack.set_int(lt::settings_pack::max_queued_disk_bytes, 512 * 1024 * 1024);
    for (bool aggressive : {true, false, true}) {
        TDApplyDiscoverySettings(pack, aggressive);
        assert(pack.get_int(lt::settings_pack::max_out_request_queue) == 2'000);
        assert(pack.get_int(lt::settings_pack::max_allowed_in_request_queue) == 4'000);
        assert(pack.get_int(lt::settings_pack::max_queued_disk_bytes) == 512 * 1024 * 1024);
        assert(pack.get_int(lt::settings_pack::peer_connect_timeout) == 15);
        assert(pack.get_int(lt::settings_pack::connection_speed) == (aggressive ? 100 : 30));
    }
    std::cout << "Discovery transitions preserve transfer queues\n";
}
