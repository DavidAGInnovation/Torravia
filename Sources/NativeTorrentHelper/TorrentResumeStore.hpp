#pragma once

#include <mutex>
#include <string>
#include <vector>
#include <sqlite3.h>

class ResumeStore {
public:
    explicit ResumeStore(const char *path) {
        if (sqlite3_open_v2(path, &database_, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nullptr) != SQLITE_OK) {
            close();
            return;
        }
        sqlite3_busy_timeout(database_, 5'000);
        if (!execute("PRAGMA journal_mode=WAL")
            || !execute("PRAGMA synchronous=FULL")
            || !execute("PRAGMA wal_autocheckpoint=64")
            || !execute("CREATE TABLE IF NOT EXISTS resume_snapshots ("
                        "torrent_id TEXT PRIMARY KEY NOT NULL,"
                        "current_blob BLOB NOT NULL,"
                        "previous_blob BLOB,"
                        "generation INTEGER NOT NULL DEFAULT 1,"
                        "updated_at INTEGER NOT NULL"
                        ") WITHOUT ROWID")) {
            close();
        }
    }

    ~ResumeStore() { close(); }
    ResumeStore(const ResumeStore &) = delete;
    ResumeStore &operator=(const ResumeStore &) = delete;

    bool available() const { return database_ != nullptr; }

    std::vector<std::vector<char>> load(const std::string &id) {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<std::vector<char>> result;
        if (database_ == nullptr) { return result; }
        sqlite3_stmt *statement = nullptr;
        if (sqlite3_prepare_v2(database_,
                "SELECT current_blob, previous_blob FROM resume_snapshots WHERE torrent_id=?1",
                -1, &statement, nullptr) != SQLITE_OK) { return result; }
        sqlite3_bind_text(statement, 1, id.c_str(), -1, SQLITE_TRANSIENT);
        if (sqlite3_step(statement) == SQLITE_ROW) {
            for (int column = 0; column < 2; ++column) {
                const auto *bytes = static_cast<const char *>(sqlite3_column_blob(statement, column));
                const int count = sqlite3_column_bytes(statement, column);
                if (bytes != nullptr && count > 0) {
                    result.emplace_back(bytes, bytes + count);
                }
            }
        }
        sqlite3_finalize(statement);
        return result;
    }

    bool save(const std::string &id, const std::vector<char> &data) {
        if (data.empty()) { return false; }
        std::lock_guard<std::mutex> lock(mutex_);
        if (database_ == nullptr || !executeUnlocked("BEGIN IMMEDIATE")) { return false; }
        sqlite3_stmt *statement = nullptr;
        const char *sql =
            "INSERT INTO resume_snapshots(torrent_id,current_blob,previous_blob,generation,updated_at) "
            "VALUES(?1,?2,NULL,1,strftime('%s','now')) "
            "ON CONFLICT(torrent_id) DO UPDATE SET "
            "previous_blob=current_blob,current_blob=excluded.current_blob,"
            "generation=generation+1,updated_at=excluded.updated_at";
        bool succeeded = sqlite3_prepare_v2(database_, sql, -1, &statement, nullptr) == SQLITE_OK;
        if (succeeded) {
            sqlite3_bind_text(statement, 1, id.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_bind_blob(statement, 2, data.data(), static_cast<int>(data.size()), SQLITE_TRANSIENT);
            succeeded = sqlite3_step(statement) == SQLITE_DONE;
        }
        sqlite3_finalize(statement);
        succeeded = succeeded && executeUnlocked("COMMIT");
        if (!succeeded) { executeUnlocked("ROLLBACK"); }
        return succeeded;
    }

    void remove(const std::string &id) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (database_ == nullptr) { return; }
        sqlite3_stmt *statement = nullptr;
        if (sqlite3_prepare_v2(database_, "DELETE FROM resume_snapshots WHERE torrent_id=?1",
                              -1, &statement, nullptr) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, id.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_step(statement);
        }
        sqlite3_finalize(statement);
    }

private:
    bool execute(const char *sql) {
        std::lock_guard<std::mutex> lock(mutex_);
        return executeUnlocked(sql);
    }
    bool executeUnlocked(const char *sql) {
        return database_ != nullptr && sqlite3_exec(database_, sql, nullptr, nullptr, nullptr) == SQLITE_OK;
    }
    void close() {
        if (database_ != nullptr) { sqlite3_close(database_); database_ = nullptr; }
    }
    sqlite3 *database_ = nullptr;
    std::mutex mutex_;
};
