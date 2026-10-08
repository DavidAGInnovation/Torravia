#pragma once

#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "libtorrent/download_priority.hpp"
#include "libtorrent/torrent_handle.hpp"
#include "libtorrent/torrent_info.hpp"
#include "TorrentStorageKind.hpp"
#include "TorrentSeedingPolicy.hpp"

struct TorrentRecord {
    struct TrackerHealth {
        int successes = 0;
        int failures = 0;
        int consecutiveFailures = 0;
        int lastPeerCount = 0;
        std::chrono::steady_clock::time_point cooldownUntil{};
    };

    std::string id;
    std::string input;
    std::string destination;
    std::string contentRoot;
    std::string layoutName;
    int layoutRenamesPending = 0;
    bool layoutMoving = false;
    bool layoutFailed = false;
    bool seedOnly = false;
    libtorrent::torrent_handle handle;
    std::vector<libtorrent::tcp::endpoint> manuallyAddedPeers;
    std::shared_ptr<const libtorrent::torrent_info> torrentInfo;
    // Keeps the metadata cookie used by async_add_torrent alive while
    // libtorrent retains it on the torrent handle.
    std::shared_ptr<void> asyncAddUserData;
    bool addedEmitted = false;
    bool doneEmitted = false;
    bool completionFlushPending = false;
    bool completionFlushed = false;
    bool recheckPending = false;
    bool stopRequested = false;
    bool completionSent = false;
    bool resumeSavePending = false;
    bool pauseRequested = false;
    bool resumeRejected = false;
    bool firstLastPiecePriority = false;
    std::vector<libtorrent::download_priority_t> configuredFilePriorities;
    double shareRatioLimit = 0.0;
    int shareRatioAction = 0;
    bool shareRatioTriggered = false;
    std::int64_t seedingTimeLimitSeconds = 0;
    std::int64_t inactiveSeedingTimeLimitSeconds = 0;
    TDSeedingClock seedingClock;
    bool seedingClockRestored = false;
    std::string lastError;
    // Discovery is scheduled per torrent so a stalled transfer can recover
    // independently without creating a burst of announces for every torrent.
    std::chrono::steady_clock::time_point nextDiscoveryAttempt{};
    std::chrono::steady_clock::time_point nextTrackerAnnounce{};
    int discoveryFailures = 0;
    int trackerReplyPeers = -1;
    bool adaptiveTrackersApplied = false;
    TDStorageKind storageKind = TDStorageKind::unknown;

    // The libtorrent disk and send queues are session-wide. These fields
    // keep demand per torrent so the session-level value can be derived from
    // the active torrents instead of letting one warning permanently raise
    // the ceiling for every transfer.
    int adaptiveDiskQueueBytes = 256 * 1024 * 1024;
    int adaptiveSendBufferBytes = 2 * 1024 * 1024;
    double throughputEwma = 0.0;
    double peerConnectSuccessEwma = 0.0;
    std::int64_t lastWantedDone = 0;
    std::chrono::steady_clock::time_point lastTelemetrySample{};
    std::chrono::steady_clock::time_point lastAdaptiveIncrease{};
    int peerConnectSuccesses = 0;
    int peerConnectFailures = 0;
    int diskLimitWarnings = 0;
    int requestLimitWarnings = 0;
    bool pendingDiskQueueIncrease = false;
    bool pendingSendBufferIncrease = false;
    double adaptiveBaselineRate = 0.0;
    std::chrono::steady_clock::time_point adaptiveWarningAt{};
    std::unordered_map<std::string, TrackerHealth> trackerHealth;
    int appliedConnectionBudget = 0;
    int schedulerRank = -1;
};
