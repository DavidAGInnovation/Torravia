#pragma once
#include <algorithm>
#include <cstdint>

struct TDSeedingClock {
    std::int64_t seconds = 0;
    std::int64_t inactiveSeconds = 0;
    std::int64_t previousFinished = -1;
    std::int64_t previousUploaded = -1;

    void sample(bool ready, bool finished, std::int64_t nativeFinished, std::int64_t uploaded) {
        if (previousFinished < 0) { seconds = std::max(seconds, nativeFinished); }
        const auto delta = previousFinished < 0 ? 0 : std::max<std::int64_t>(nativeFinished - previousFinished, 0);
        if (ready && finished) {
            seconds += delta;
            if (previousUploaded >= 0 && uploaded > previousUploaded) { inactiveSeconds = 0; }
            else { inactiveSeconds += delta; }
        } else if (ready && !finished) { inactiveSeconds = 0; }
        previousFinished = nativeFinished;
        previousUploaded = uploaded;
    }
};

inline const char *TDReachedSeedingLimit(bool activeFinished, double ratio, double ratioLimit,
                                        const TDSeedingClock &clock, std::int64_t timeLimit,
                                        std::int64_t inactiveLimit) {
    if (!activeFinished) { return nullptr; }
    if (ratioLimit > 0 && ratio >= ratioLimit) { return "ratio"; }
    if (timeLimit > 0 && clock.seconds >= timeLimit) { return "time"; }
    if (inactiveLimit > 0 && clock.inactiveSeconds >= inactiveLimit) { return "inactivity"; }
    return nullptr;
}
