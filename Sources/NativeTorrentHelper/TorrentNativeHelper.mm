#import <Foundation/Foundation.h>

#include <atomic>
#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <sqlite3.h>
#include <unistd.h>

#include "libtorrent/add_torrent_params.hpp"
#include "libtorrent/announce_entry.hpp"
#include "libtorrent/alert_types.hpp"
#include "libtorrent/bencode.hpp"
#include "libtorrent/file_storage.hpp"
#include "libtorrent/hex.hpp"
#include "libtorrent/ip_filter.hpp"
#include "libtorrent/load_torrent.hpp"
#include "libtorrent/magnet_uri.hpp"
#include "libtorrent/posix_disk_io.hpp"
#include "libtorrent/peer_info.hpp"
#include "libtorrent/pread_disk_io.hpp"
#include "libtorrent/read_resume_data.hpp"
#include "libtorrent/session.hpp"
#include "libtorrent/session_params.hpp"
#include "libtorrent/session_stats.hpp"
#include "libtorrent/settings_pack.hpp"
#include "libtorrent/torrent_flags.hpp"
#include "libtorrent/torrent_handle.hpp"
#include "libtorrent/torrent_info.hpp"
#include "libtorrent/torrent_status.hpp"
#include "libtorrent/version.hpp"
#include "libtorrent/write_resume_data.hpp"
#if TORRENT_HAVE_MMAP || TORRENT_HAVE_MAP_VIEW_OF_FILE
#include "libtorrent/mmap_disk_io.hpp"
#endif
#include "TorrentResumeStore.hpp"
#include "TorrentSessionSettings.hpp"
#include "TorrentSessionPersistence.hpp"
#include "TorrentPeerSources.hpp"
#include "TorrentCreation.hpp"

namespace lt = libtorrent;

static std::uint64_t TDPhysicalMemoryBytes() {
    return static_cast<std::uint64_t>([NSProcessInfo processInfo].physicalMemory);
}

static int TDMemoryBoundedQueueCeiling(int floor,
                                       int requestedCeiling,
                                       std::uint64_t physicalMemory) {
    if (physicalMemory == 0) { return requestedCeiling; }
    constexpr std::uint64_t bytesPerQueueUnit = 4 * 1024 * 1024;
    const std::uint64_t memoryCeiling = physicalMemory / bytesPerQueueUnit;
    return std::clamp(static_cast<int>(std::min<std::uint64_t>(
                           memoryCeiling, static_cast<std::uint64_t>(requestedCeiling))),
                      floor, requestedCeiling);
}

static int TDMemoryBoundedDiskCeiling(int requestedCeiling,
                                      std::uint64_t physicalMemory) {
    constexpr std::uint64_t minimum = 128 * 1024 * 1024;
    constexpr std::uint64_t maximum = 1024 * 1024 * 1024;
    if (physicalMemory == 0) { return requestedCeiling; }
    const std::uint64_t memoryCeiling = std::clamp<std::uint64_t>(
        physicalMemory / 16, minimum, maximum);
    return std::min(requestedCeiling, static_cast<int>(memoryCeiling));
}

static int TDMemoryBoundedPeerBuffer(int activePeers,
                                     std::uint64_t physicalMemory) {
    constexpr int minimum = 2 * 1024 * 1024;
    constexpr int maximum = 8 * 1024 * 1024;
    if (activePeers <= 0 || physicalMemory == 0) { return minimum; }
    const std::uint64_t peerBudget = std::clamp<std::uint64_t>(
        physicalMemory / 8, 128 * 1024 * 1024, 512 * 1024 * 1024);
    const std::uint64_t perPeer = peerBudget / static_cast<std::uint64_t>(activePeers);
    return std::clamp(static_cast<int>(std::min<std::uint64_t>(
                               perPeer, static_cast<std::uint64_t>(maximum))),
                      minimum, maximum);
}

#include "TorrentNativeHelperUtilities.hpp"
#include "TorrentRecord.hpp"
#include "TorrentTrackerStatus.hpp"

class Helper {
public:
    Helper()
        : resumeStore_("resume-state.sqlite3"),
          session_(TDMakeSessionParams()),
          dhtNodesMetricIndex_(lt::find_metric_idx("dht.dht_nodes")) {}

    ~Helper() { stopResumeWriter(); }

    int run() {
        sendEvent(@{@"type": @"ready"});

        resumeWriterThread_ = std::thread([this] { resumeWriterLoop(); });
        std::thread poller([this] { pollLoop(); });
        readCommands();
        shouldStop_.store(true);
        if (poller.joinable()) {
            poller.join();
        }
        stopResumeWriter();
        TDSaveAllResumeDataSynchronously(resumeStore_, torrents_);
        TDSaveDHTState(session_);
        return 0;
    }

private:
    static std::string resumeDataPath(const std::string &id) {
        return TDResumeDataPath(id);
    }

    struct PendingResumeWrite {
        std::string id;
        std::vector<char> data;
    };

    struct PendingTorrentAdd {
        std::string id;
        std::string input;
        std::string destination;
        std::string contentRoot;
        std::string resumeWarning;
        TDStorageKind storageKind = TDStorageKind::unknown;
        bool seedOnly = false;
        bool emitResumed = false;
        bool pauseRequested = false;
        bool cancelRequested = false;
        bool deleteData = false;
    };

    void enqueueResumeWrite(const std::string &id, std::vector<char> data) {
        if (id.empty() || data.empty()) { return; }
        {
            std::lock_guard<std::mutex> lock(resumeWriteMutex_);
            // Coalesce progress snapshots for the same torrent. The newest
            // snapshot is always sufficient and prevents a slow disk from
            // turning a burst of alerts into an unbounded write queue.
            auto existing = std::find_if(
                resumeWriteQueue_.begin(), resumeWriteQueue_.end(),
                [&](const PendingResumeWrite &pending) { return pending.id == id; });
            if (existing != resumeWriteQueue_.end()) {
                existing->data = std::move(data);
            } else {
                resumeWriteQueue_.push_back(PendingResumeWrite{id, std::move(data)});
            }
        }
        resumeWriteCondition_.notify_one();
    }

    void resumeWriterLoop() {
        for (;;) {
            PendingResumeWrite pending;
            {
                std::unique_lock<std::mutex> lock(resumeWriteMutex_);
                resumeWriteCondition_.wait(lock, [&] {
                    return resumeWriterStopping_ || !resumeWriteQueue_.empty();
                });
                if (resumeWriteQueue_.empty() && resumeWriterStopping_) {
                    return;
                }
                pending = std::move(resumeWriteQueue_.front());
                resumeWriteQueue_.pop_front();
            }

            if (!TDWriteResumeBuffer(resumeStore_, pending.id, pending.data)) {
                sendEvent(@{@"type": @"warning",
                            @"id": TDNSString(pending.id),
                            @"message": @"Resume snapshot could not be persisted."});
            }
        }
    }

    void stopResumeWriter() {
        {
            std::lock_guard<std::mutex> lock(resumeWriteMutex_);
            resumeWriterStopping_ = true;
        }
        resumeWriteCondition_.notify_one();
        if (resumeWriterThread_.joinable()) {
            resumeWriterThread_.join();
        }
    }

    void saveDHTState() {
        TDSaveDHTState(session_);
    }

#include "TorrentNativeHelperCommands.inl"
#include "TorrentNativeHelperTorrentLifecycle.inl"
#include "TorrentNativeHelperTorrentActions.inl"
#include "TorrentNativeHelperPayloads.inl"
#include "TorrentNativeHelperRuntime.inl"
#include "TorrentNativeHelperAlerts.inl"
#include "TorrentNativeHelperEvents.inl"

    std::mutex mutex_;
    std::mutex outputMutex_;
    std::mutex resumeWriteMutex_;
    std::condition_variable resumeWriteCondition_;
    std::deque<PendingResumeWrite> resumeWriteQueue_;
    std::thread resumeWriterThread_;
    bool resumeWriterStopping_ = false;
    std::unordered_map<std::string, TorrentRecord> torrents_;
    std::unordered_map<std::string, std::shared_ptr<PendingTorrentAdd>> pendingAdds_;
    std::atomic<bool> shouldStop_{false};
    const bool peerDiagnosticsEnabled_ = [] {
        const char *value = std::getenv("TORRAVIA_PEER_DIAGNOSTICS");
        if (value == nullptr) { value = std::getenv("TORRENTSCOUT_PEER_DIAGNOSTICS"); }
        return value != nullptr && std::strcmp(value, "1") == 0;
    }();
    ResumeStore resumeStore_;
    lt::session session_;

    int connectionLimit_ = 500;
    int perTorrentConnectionLimit_ = 100;
    bool queueingEnabled_ = false;
    int maximumActiveDownloads_ = 3;
    int maximumActiveSeeds_ = 3;
    int maximumActiveTorrents_ = 5;
    bool ignoreSlowTorrents_ = false;
    int globalUploadSlots_ = 20;
    int perTorrentUploadSlots_ = 4;
    bool dhtEnabled_ = true;
    bool peerExchangeEnabled_ = true;
    bool localPeerDiscoveryEnabled_ = true;
    bool preallocateFiles_ = false;
    std::vector<std::string> additionalTrackerURLs_;
    std::vector<std::string> adaptiveTrackerURLs_;
    std::unordered_set<std::string> peerDetailSubscriptions_;
    std::unordered_set<std::string> bannedPeers_;
    int listenPort_ = 0;
    std::string listenState_ = "starting";
    std::string upnpStatus_ = "pending";
    std::string natpmpStatus_ = "pending";
    std::string trackerStatus_ = "waiting";
    std::string lastTrackerURL_;
    std::string lastTrackerError_;
    int trackerAnnounces_ = 0;
    int trackerReplies_ = 0;
    int trackerErrors_ = 0;
    std::uint64_t alertsDropped_ = 0;
    std::atomic<bool> listenRecoveryPending_{false};
    std::string dhtStatus_ = "starting";
    int dhtReplies_ = 0;
    const int dhtNodesMetricIndex_;
    int dhtNodes_ = 0;
    bool networkStatusDirty_ = true;
    int adaptiveDiskQueueBytes_ = 256 * 1024 * 1024;
    int adaptiveRequestQueue_ = TDNormalOutboundRequestQueue;
    int adaptiveInboundRequestQueue_ = TDNormalInboundRequestQueue;
    int adaptiveSendBufferBytes_ = 2 * 1024 * 1024;
    int adaptivePeerRecvBufferBytes_ = 2 * 1024 * 1024;
    int adaptiveSocketBufferBytes_ = 2 * 1024 * 1024;
    int baseDiskQueueBytes_ = 256 * 1024 * 1024;
    bool aggressiveDiscoveryEnabled_ = false;
    bool sessionConfigurationApplied_ = false;
    std::string networkInterfaceWarning_;
    std::mutex hashingTuningMutex_;
    int hashingThreads_ = 1;
};

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && std::string(argv[1]) == "--create-torrent") {
            return TDCreateTorrent();
        }
        try {
            Helper helper;
            return helper.run();
        } catch (const std::exception &ex) {
            std::cerr << "{\"type\":\"error\",\"message\":\"" << ex.what() << "\"}\n";
            return 1;
        }
    }
}
