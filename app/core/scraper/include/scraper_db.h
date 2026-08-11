#pragma once

/// Archoera 刮削器 — 直写 scraper-state.db
///
/// 替代 TS 层的 /api/db/scrape/* HTTP 代理，C++ scraper 直接操作独立的 scraper-state.db。
/// 数据不经过 Node.js / V8 堆，降低 TS 依赖度。
///
/// 仍保留 HTTP 调用：
///   - DbClient::getTrack() — 读取 library.db 中的曲目元数据（跨库，TAG/刮削字段由 TS 管理）
///
/// 线程安全：sqlite3 连接默认是串行化的（SQLITE_OPEN_FULLMUTEX），天然单写安全。

#include <sqlite3.h>
#include <string>
#include <vector>
#include <stdexcept>
#include <cstdio>

#include "scraper.h"

namespace archoera::scraper {

/// RAII 封装 sqlite3
class ScraperDb {
public:
    explicit ScraperDb(const std::string& dbPath) {
        int rc = sqlite3_open_v2(dbPath.c_str(), &db_,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nullptr);
        if (rc != SQLITE_OK) {
            lastError_ = std::string("sqlite3_open: ") + sqlite3_errmsg(db_);
            sqlite3_close(db_);
            db_ = nullptr;
            throw std::runtime_error(lastError_);
        }
        exec("PRAGMA journal_mode = WAL");
        exec("PRAGMA busy_timeout = 5000"); // 5s 等待，避免跟 TS scraper-state.db 操作冲突

        exec(R"(
            CREATE TABLE IF NOT EXISTS scrape_queue (
                track_id TEXT PRIMARY KEY,
                status TEXT NOT NULL DEFAULT 'pending',
                retries INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_scrape_queue_status ON scrape_queue(status);
        )");
    }

    ~ScraperDb() {
        if (db_) sqlite3_close(db_);
    }

    ScraperDb(const ScraperDb&) = delete;
    ScraperDb& operator=(const ScraperDb&) = delete;

    // ---- 队列操作 ----

    /// 原子领取待刮削任务：pending → running，事务内完成
    std::vector<QueueItem> claimQueue(int limit) {
        std::vector<QueueItem> items;
        exec("BEGIN IMMEDIATE");

        const char* sel = R"(
            SELECT track_id, status, retries, COALESCE(last_error, '')
            FROM scrape_queue
            WHERE status = 'pending'
            ORDER BY retries ASC, created_at ASC
            LIMIT ?
        )";
        sqlite3_stmt* stmt = prepare(sel);
        sqlite3_bind_int(stmt, 1, limit);

        while (sqlite3_step(stmt) == SQLITE_ROW) {
            QueueItem qi;
            qi.trackId     = colText(stmt, 0);
            qi.status      = colText(stmt, 1);
            qi.retries     = sqlite3_column_int(stmt, 2);
            qi.lastError   = colText(stmt, 3);
            items.push_back(std::move(qi));
        }
        sqlite3_finalize(stmt);

        // 标记 running
        if (!items.empty()) {
            const char* upd = "UPDATE scrape_queue SET status = 'running', updated_at = ? WHERE track_id = ?";
            stmt = prepare(upd);
            int64_t now = nowMs();
            for (const auto& item : items) {
                sqlite3_bind_int64(stmt, 1, now);
                sqlite3_bind_text(stmt, 2, item.trackId.c_str(), -1, SQLITE_TRANSIENT);
                sqlite3_step(stmt);
                sqlite3_reset(stmt);
            }
            sqlite3_finalize(stmt);
        }

        exec("COMMIT");
        return items;
    }

    /// 更新队列状态，含自动重试逻辑
    void updateQueueStatus(const std::string& trackId, const std::string& status,
                           const std::string& lastError = "") {
        int64_t now = nowMs();

        if (status == "not_found") {
            // 数据源无匹配 → 直接隔离，不重试
            exec("BEGIN IMMEDIATE");
            int retries = getRetries(trackId) + 1;
            execUpsert(trackId, "quarantined", retries, lastError, now);
            exec("COMMIT");
            std::fprintf(stderr, "[scraper-db] %s 无匹配隔离\n", trackId.c_str());
        } else if (status == "failed") {
            // 标签写入失败 → 允许重试（最多 5 次）
            exec("BEGIN IMMEDIATE");
            int retries = getRetries(trackId) + 1;
            if (retries < 5) {
                execUpsert(trackId, "pending", retries, lastError, now);
                std::fprintf(stderr, "[scraper-db] %s 失败后归位 pending (retry=%d/5)\n",
                             trackId.c_str(), retries);
            } else {
                execUpsert(trackId, "quarantined", retries, lastError, now);
                std::fprintf(stderr, "[scraper-db] %s 已隔离 (retry=%d)\n",
                             trackId.c_str(), retries);
            }
            exec("COMMIT");
        } else {
            // 非失败状态：直接更新
            exec("BEGIN IMMEDIATE");
            execUpsert(trackId, status, 0, lastError, now);
            exec("COMMIT");
        }
    }

    /// 重置卡住的任务（crash 恢复）：running 超过 timeoutMin 分钟的归位 pending
    /// 不递增 retries — crash 是系统故障，不应消耗重试配额
    int resetStuck(int timeoutMin, int limit = 500) {
        if (timeoutMin <= 0) return 0;
        int64_t threshold = nowMs() - int64_t(timeoutMin) * 60 * 1000;

        const char* sql = R"(
            UPDATE scrape_queue
            SET status = 'pending', last_error = 'timeout reset'
            WHERE status = 'running' AND updated_at < ?
            LIMIT ?
        )";
        sqlite3_stmt* stmt = prepare(sql);
        sqlite3_bind_int64(stmt, 1, threshold);
        sqlite3_bind_int(stmt, 2, limit);
        sqlite3_step(stmt);
        int changes = sqlite3_changes(db_);
        sqlite3_finalize(stmt);

        if (changes > 0) {
            // 先查询所有被隔离的 track_id 并记录日志
            const char* selectQuarantined = "SELECT track_id, last_error FROM scrape_queue WHERE status = 'quarantined'";
            sqlite3_stmt* selStmt = prepare(selectQuarantined);
            while (sqlite3_step(selStmt) == SQLITE_ROW) {
                std::string tid = colText(selStmt, 0);
                std::string err = colText(selStmt, 1);
                std::fprintf(stderr, "[scraper-db] 清理隔离项: %s (原因: %s)\n", tid.c_str(), err.c_str());
            }
            sqlite3_finalize(selStmt);

            // 再删除
            exec("DELETE FROM scrape_queue WHERE status = 'quarantined'");
        }

        return changes;
    }

    /// 释放指定任务：running → pending（干净取消）
    int releaseItems(const std::vector<std::string>& trackIds) {
        if (trackIds.empty()) return 0;

        exec("BEGIN IMMEDIATE");
        const char* sql = R"(
            UPDATE scrape_queue
            SET status = 'pending', last_error = 'canceled', updated_at = ?
            WHERE track_id = ? AND status = 'running'
        )";
        sqlite3_stmt* stmt = prepare(sql);
        int total = 0;
        int64_t now = nowMs();
        for (const auto& id : trackIds) {
            sqlite3_bind_int64(stmt, 1, now);
            sqlite3_bind_text(stmt, 2, id.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
            total += sqlite3_changes(db_);
            sqlite3_reset(stmt);
        }
        sqlite3_finalize(stmt);
        exec("COMMIT");
        return total;
    }

    /// 心跳保活：更新 running 任务的 updated_at
    int heartbeat(const std::vector<std::string>& trackIds) {
        if (trackIds.empty()) return 0;

        const char* sql = "UPDATE scrape_queue SET updated_at = ? WHERE track_id = ? AND status = 'running'";
        sqlite3_stmt* stmt = prepare(sql);
        int64_t now = nowMs();
        int total = 0;
        for (const auto& id : trackIds) {
            sqlite3_bind_int64(stmt, 1, now);
            sqlite3_bind_text(stmt, 2, id.c_str(), -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
            total += sqlite3_changes(db_);
            sqlite3_reset(stmt);
        }
        sqlite3_finalize(stmt);
        return total;
    }

    /// (兼容旧接口) 简单读取 pending 队列
    std::vector<QueueItem> fetchQueue(int limit) {
        std::vector<QueueItem> items;
        const char* sel = R"(
            SELECT track_id, status, retries, COALESCE(last_error, '')
            FROM scrape_queue
            WHERE status = 'pending'
            ORDER BY retries ASC, created_at ASC
            LIMIT ?
        )";
        sqlite3_stmt* stmt = prepare(sel);
        sqlite3_bind_int(stmt, 1, limit);

        while (sqlite3_step(stmt) == SQLITE_ROW) {
            QueueItem qi;
            qi.trackId   = colText(stmt, 0);
            qi.status    = colText(stmt, 1);
            qi.retries   = sqlite3_column_int(stmt, 2);
            qi.lastError = colText(stmt, 3);
            items.push_back(std::move(qi));
        }
        sqlite3_finalize(stmt);
        return items;
    }

    const std::string& lastError() const { return lastError_; }

private:
    static int64_t nowMs() {
        using namespace std::chrono;
        return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
    }

    void exec(const char* sql) {
        char* err = nullptr;
        int rc = sqlite3_exec(db_, sql, nullptr, nullptr, &err);
        if (rc != SQLITE_OK) {
            std::string msg = err ? err : sqlite3_errmsg(db_);
            sqlite3_free(err);
            throw std::runtime_error("sqlite3_exec: " + msg);
        }
    }

    sqlite3_stmt* prepare(const char* sql) {
        sqlite3_stmt* stmt = nullptr;
        int rc = sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr);
        if (rc != SQLITE_OK) {
            throw std::runtime_error(std::string("sqlite3_prepare: ") + sqlite3_errmsg(db_));
        }
        return stmt;
    }

    static std::string colText(sqlite3_stmt* stmt, int col) {
        const char* s = reinterpret_cast<const char*>(sqlite3_column_text(stmt, col));
        return s ? std::string(s) : std::string();
    }

    int getRetries(const std::string& trackId) {
        const char* sql = "SELECT retries FROM scrape_queue WHERE track_id = ?";
        sqlite3_stmt* stmt = prepare(sql);
        sqlite3_bind_text(stmt, 1, trackId.c_str(), -1, SQLITE_TRANSIENT);
        int retries = (sqlite3_step(stmt) == SQLITE_ROW) ? sqlite3_column_int(stmt, 0) : 0;
        sqlite3_finalize(stmt);
        return retries;
    }

    void execUpsert(const std::string& trackId, const std::string& status,
                    int retries, const std::string& lastError, int64_t now) {
        (void)retries; // only used in status='quarantined' or 'pending' case
        const char* sql = R"(
            INSERT INTO scrape_queue (track_id, status, retries, last_error, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(track_id) DO UPDATE SET
                status = excluded.status,
                retries = excluded.retries,
                last_error = excluded.last_error,
                updated_at = excluded.updated_at
        )";
        sqlite3_stmt* stmt = prepare(sql);
        sqlite3_bind_text(stmt, 1, trackId.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, status.c_str(), -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt, 3, retries);
        const char* err = lastError.empty() ? nullptr : lastError.c_str();
        if (err) sqlite3_bind_text(stmt, 4, err, -1, SQLITE_TRANSIENT);
        else     sqlite3_bind_null(stmt, 4);
        sqlite3_bind_int64(stmt, 5, now);
        sqlite3_bind_int64(stmt, 6, now);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }

    sqlite3* db_ = nullptr;
    std::string lastError_;
};

} // namespace archoera::scraper
