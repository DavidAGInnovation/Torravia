#pragma once

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "libtorrent/read_resume_data.hpp"
#include "libtorrent/posix_disk_io.hpp"
#include "libtorrent/pread_disk_io.hpp"
#include "libtorrent/session.hpp"
#if TORRENT_HAVE_MMAP || TORRENT_HAVE_MAP_VIEW_OF_FILE
#include "libtorrent/mmap_disk_io.hpp"
#endif
#include "libtorrent/write_resume_data.hpp"
#include "TorrentRecord.hpp"
#include "TorrentResumeStore.hpp"
#include "TorrentSessionSettings.hpp"

static constexpr const char *TDNativeDHTStatePath = "dht-session.state";

static std::string TDResumeDataPath(const std::string &id) {
        return "torrent-" + id + ".fastresume";
    }

static bool TDWriteResumeBuffer(ResumeStore &resumeStore,
                                const std::string &id,
                                const std::vector<char> &data) {
        if (data.empty()) { return false; }

        if (resumeStore.save(id, data)) { return true; }
        const std::string path = TDResumeDataPath(id);
        const std::string temporaryPath = path + ".tmp";
        std::ofstream output(temporaryPath, std::ios::binary | std::ios::trunc);
        if (!output) { return false; }
        output.write(data.data(), static_cast<std::streamsize>(data.size()));
        output.close();
        if (!output) { return false; }
        return std::rename(temporaryPath.c_str(), path.c_str()) == 0;
}

static bool TDWriteResumeData(ResumeStore &resumeStore,
                              const std::string &id,
                              const libtorrent::add_torrent_params &params) {
        try {
            return TDWriteResumeBuffer(resumeStore, id,
                                       libtorrent::write_resume_data_buf(params));
        } catch (...) {
            return false;
        }
}

static libtorrent::session_params TDMakeSessionParams() {
        libtorrent::session_params params(TDMakeSessionSettings());
        // Keep the session paused until the app has sent its complete network
        // configuration. This prevents torrents added immediately after the
        // helper's ready event from opening sockets with transient defaults.
        params.flags |= libtorrent::session::paused;
        const char *backend = std::getenv("TORRAVIA_DISK_IO_BACKEND");
        if (backend == nullptr) { backend = std::getenv("TORRENTSCOUT_DISK_IO_BACKEND"); }
        if (backend != nullptr) {
            const std::string selected(backend);
            if (selected == "posix") {
                params.disk_io_constructor = libtorrent::posix_disk_io_constructor;
            } else if (selected == "pread") {
                params.disk_io_constructor = libtorrent::pread_disk_io_constructor;
#if TORRENT_HAVE_MMAP || TORRENT_HAVE_MAP_VIEW_OF_FILE
            } else if (selected == "mmap") {
                params.disk_io_constructor = libtorrent::mmap_disk_io_constructor;
#endif
            }
        }
        std::ifstream input(TDNativeDHTStatePath, std::ios::binary);
        if (!input) { return params; }

        std::vector<char> data((std::istreambuf_iterator<char>(input)),
                               std::istreambuf_iterator<char>());
        if (data.empty()) { return params; }

        try {
            libtorrent::session_params saved = libtorrent::read_session_params(
                {data.data(), static_cast<std::ptrdiff_t>(data.size())},
                libtorrent::session_handle::save_dht_state);
            params.dht_state = std::move(saved.dht_state);
        } catch (...) {
            // A corrupt or incompatible cache should never prevent startup.
        }
        return params;
}

static void TDSaveDHTState(libtorrent::session &session) {
        try {
            const auto flags = libtorrent::session_handle::save_dht_state;
            std::vector<char> data = libtorrent::write_session_params_buf(
                session.session_state(flags), flags);
            if (data.empty()) { return; }

            const std::string temporaryPath = std::string(TDNativeDHTStatePath) + ".tmp";
            std::ofstream output(temporaryPath, std::ios::binary | std::ios::trunc);
            if (!output) { return; }
            output.write(data.data(), static_cast<std::streamsize>(data.size()));
            output.close();
            if (output) {
                std::rename(temporaryPath.c_str(), TDNativeDHTStatePath);
            }
        } catch (...) {
            // DHT persistence is an optimization; downloads still work without it.
        }
}

static void TDSaveAllResumeDataSynchronously(ResumeStore &resumeStore,
                                             const std::unordered_map<std::string, TorrentRecord> &torrents) {
        std::vector<std::pair<std::string, libtorrent::torrent_handle>> snapshots;
        snapshots.reserve(torrents.size());
        for (const auto &entry : torrents) {
            if (entry.second.handle.is_valid()) {
                snapshots.emplace_back(entry.first, entry.second.handle);
            }
        }

        for (const auto &entry : snapshots) {
            try {
                TDWriteResumeData(resumeStore, entry.first, entry.second.get_resume_data(
                    libtorrent::torrent_handle::save_info_dict));
            } catch (...) {
                // A failed resume snapshot must not prevent helper shutdown.
            }
        }
}
