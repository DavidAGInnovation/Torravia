#include <cassert>
#include <string>
#include "../../Sources/NativeTorrentHelper/TorrentSeedingPolicy.hpp"

int main() {
    TDSeedingClock clock;
    clock.sample(true, false, 0, 0);
    clock.sample(true, true, 30, 0);
    assert(clock.seconds == 30 && clock.inactiveSeconds == 30);
    // Paused/offline samples do not advance libtorrent's active finished time.
    clock.sample(true, true, 30, 0);
    assert(clock.seconds == 30 && clock.inactiveSeconds == 30);
    // Any newly uploaded payload resets the inactivity interval.
    clock.sample(true, true, 40, 16384);
    assert(clock.seconds == 40 && clock.inactiveSeconds == 0);
    clock.sample(true, true, 50, 16384);
    assert(clock.inactiveSeconds == 10);
    assert(TDReachedSeedingLimit(false, 3, 2, clock, 40, 5) == nullptr);
    assert(std::string(TDReachedSeedingLimit(true, 3, 2, clock, 40, 5)) == "ratio");
    assert(std::string(TDReachedSeedingLimit(true, 0, 0, clock, 40, 5)) == "time");
    assert(std::string(TDReachedSeedingLimit(true, 0, 0, clock, 0, 5)) == "inactivity");
    assert(TDReachedSeedingLimit(true, 0, 0, clock, 0, 0) == nullptr);
    // Restored clocks retain elapsed active time without adding offline time.
    TDSeedingClock restored;
    restored.seconds = 50;
    restored.inactiveSeconds = 10;
    restored.sample(true, true, 50, 16384);
    assert(restored.seconds == 50 && restored.inactiveSeconds == 10);
    restored.sample(true, true, 55, 16384);
    assert(restored.seconds == 55 && restored.inactiveSeconds == 15);
    restored.sample(true, false, 55, 16384);
    assert(restored.inactiveSeconds == 0);
}
