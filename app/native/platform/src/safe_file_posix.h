// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 安全文件原语（POSIX：Linux / macOS 共用，header-only static inline）。
//!
//! 目的：收口 Dart `SafeFile`（app/lib/utils/safe_file.dart）记录的 TOCTOU 残余
//! ——`dart:io` 无 `O_NONBLOCK`/`O_NOFOLLOW`，类型判定与真正读写之间存在极窄
//! 竞态窗口。这里以**原生 open(2)** 一次性完成「打开即校验」：
//!   - 读：`O_RDONLY|O_NONBLOCK|O_CLOEXEC`（`allow_symlink=false` 追加
//!     `O_NOFOLLOW`）→ `fstat` 必须是**普通文件**（FIFO/设备/目录/超限一律拒绝；
//!     `O_NONBLOCK` 保证 FIFO 打开阶段不阻塞）；
//!   - 写：同目录随机唯一临时名 + `O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC` 独占创建
//!     → 写全 → `fsync` → `rename` 覆盖（`rename` 不跟随符号链接，只替换链接本身）。
//!
//! 仅由 backend_linux.cpp / backend_macos.mm 包含；参数校验与错误码映射在调用方。
//! 命名：本原语属自有实现，不照搬上游标识符。

#ifndef ARCHOERA_SAFE_FILE_POSIX_H
#define ARCHOERA_SAFE_FILE_POSIX_H

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>
#include <string>

#include "core.h"

namespace archoera {

// 读普通文件到调用方缓冲。out==nullptr 时仅探测大小（写 *inout_len）。
// 语义与 include/archoera_platform.h 的 apl_file_read 一致。
static inline int32_t safeFileReadPosix(const char* path, bool allow_symlink,
                                        int64_t max_bytes, uint8_t* out,
                                        size_t* inout_len) {
    if (path == nullptr || inout_len == nullptr || max_bytes <= 0) return ERR_STATE;
    int flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK;
    if (!allow_symlink) flags |= O_NOFOLLOW;
    const int fd = ::open(path, flags);
    if (fd < 0) return ERR_BACKEND;
    // 打开后立即按**句柄**判定类型（无 TOCTOU）：普通文件才继续。
    struct stat st;
    if (::fstat(fd, &st) != 0) {
        ::close(fd);
        return ERR_BACKEND;
    }
    if (!S_ISREG(st.st_mode)) {
        ::close(fd);
        return ERR_STATE;  // FIFO / 设备 / 目录 / 符号链接（O_NOFOLLOW 时）
    }
    if (st.st_size < 0 || static_cast<int64_t>(st.st_size) > max_bytes) {
        ::close(fd);
        return ERR_STATE;  // 超限（读之前按元数据拒绝，避免 OOM）
    }
    const uint64_t size = static_cast<uint64_t>(st.st_size);
    if (out == nullptr) {  // 探测大小
        ::close(fd);
        *inout_len = static_cast<size_t>(size);
        return OK;
    }
    if (*inout_len < static_cast<size_t>(size)) {
        ::close(fd);
        return ERR_STATE;  // 调用方缓冲不足（应先探测）
    }
    size_t got = 0;
    while (got < static_cast<size_t>(size)) {
        const ssize_t n = ::read(fd, out + got, static_cast<size_t>(size) - got);
        if (n < 0) {
            if (errno == EINTR) continue;
            ::close(fd);
            return ERR_BACKEND;
        }
        if (n == 0) break;  // 并发截断：按实际读到的长度返回
        got += static_cast<size_t>(n);
    }
    ::close(fd);
    *inout_len = got;
    return OK;
}

// 原子写：同目录随机唯一临时名（O_CREAT|O_EXCL|O_NOFOLLOW）→ 写全 → fsync → rename。
static inline int32_t safeFileWriteAtomicPosix(const char* path, const uint8_t* data,
                                               size_t len) {
    if (path == nullptr || (len > 0 && data == nullptr)) return ERR_STATE;
    const std::string p(path);
    const size_t slash = p.find_last_of('/');
    std::string dir = (slash == std::string::npos) ? std::string(".") : p.substr(0, slash);
    if (dir.empty()) dir = "/";

    // 进程内自增 + 随机，避免多会话/多实例并发互相覆盖临时名。
    static std::atomic<uint64_t> counter{0};
    const uint64_t seq = counter.fetch_add(1, std::memory_order_relaxed);
    const uint64_t rnd = (static_cast<uint64_t>(std::random_device{}()) << 32) ^
                         static_cast<uint64_t>(std::random_device{}());
    char tmp[4096];
    const int n = std::snprintf(tmp, sizeof(tmp), "%s/.archoera-safe.%ld.%llu.%llu.tmp",
                                dir.c_str(), static_cast<long>(::getpid()),
                                static_cast<unsigned long long>(seq),
                                static_cast<unsigned long long>(rnd));
    if (n <= 0 || static_cast<size_t>(n) >= sizeof(tmp)) return ERR_STATE;

    const int fd = ::open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return ERR_BACKEND;
    bool ok = true;
    size_t written = 0;
    while (written < len) {
        const ssize_t w = ::write(fd, data + written, len - written);
        if (w < 0) {
            if (errno == EINTR) continue;
            ok = false;
            break;
        }
        written += static_cast<size_t>(w);
    }
    if (ok && ::fsync(fd) != 0) ok = false;
    // 打开后再验类型（防 O_NOFOLLOW 之外的边角）：非普通文件即放弃。
    if (ok) {
        struct stat st;
        if (::fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) ok = false;
    }
    if (::close(fd) != 0) ok = false;
    if (!ok) {
        ::unlink(tmp);
        return ERR_BACKEND;
    }
    if (::rename(tmp, path) != 0) {
        ::unlink(tmp);
        return ERR_BACKEND;
    }
    return OK;
}

}  // namespace archoera

#endif  // ARCHOERA_SAFE_FILE_POSIX_H
