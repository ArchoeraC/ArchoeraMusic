// ArchoeraMusic 平台能力原生桥接
// Copyright (C) 2026 Archoera && BetaStudio2
// SPDX-License-Identifier: AGPL-3.0-or-later

//! 显卡枚举与快照（Linux 实现，`apl_gpu_list`）。
//!
//! 数据来源全部是 sysfs，不启子进程、不需要 root：
//! - 卡片：`/sys/class/drm/card[0-9]+`（跳过 `card0-DP-1` 这类连接器条目）；
//! - 驱动：`<card>/device/driver`（符号链接 → amdgpu / i915 / xe / nouveau …）；
//! - 厂商：PCI `vendor`/`device` 文件（`8086:7a70` 这类），并映射为可读厂商名；
//! - 温度：`<card>/device/hwmon/hwmonN/temp1_input`（毫摄氏度）；
//! - 占用/显存：amdgpu 的 `gpu_busy_percent`、`mem_info_vram_{total,used}`；
//! - 频率：i915/xe 的 `gt_cur_freq_mhz`；amdgpu 从 `pp_dpm_sclk` 里带 `*` 的那行取。
//!
//! 不可得的项一律留 -1（Intel 的占用率需要 fdinfo 客户端统计，暂不做）。

#include "sysinfo.h"

#if defined(__linux__)

#include "core.h"

#include <dirent.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace archoera {
namespace sysinfo {
namespace {

std::mutex g_gpu_mtx;

// AplString 指向这些缓冲；与其它快照 API 一样，仅在该次调用后、下一次调用前有效。
std::vector<std::string> g_gpu_names;
std::vector<std::string> g_gpu_drivers;
std::vector<std::string> g_gpu_pci;

bool readText(const std::string& path, std::string* out) {
    FILE* f = std::fopen(path.c_str(), "r");
    if (f == nullptr) return false;
    char buf[512];
    const size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
    std::fclose(f);
    if (n == 0) return false;
    buf[n] = '\0';
    std::string s(buf);
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ' || s.back() == '\t')) {
        s.pop_back();
    }
    if (out != nullptr) *out = s;
    return true;
}

bool readLong(const std::string& path, long long* out) {
    std::string s;
    if (!readText(path, &s) || s.empty()) return false;
    *out = std::strtoll(s.c_str(), nullptr, 10);
    return true;
}

// 解析 `0x8086` → "8086"；宽高写进 pci_id 的 "vendor:device"。
std::string hex4(const std::string& raw) {
    std::string s = raw;
    if (s.rfind("0x", 0) == 0 || s.rfind("0X", 0) == 0) s = s.substr(2);
    while (s.size() < 4) s.insert(s.begin(), '0');
    return s;
}

std::vector<std::string> drmCards() {
    std::vector<std::string> out;
    DIR* d = opendir("/sys/class/drm");
    if (d == nullptr) return out;
    while (struct dirent* e = readdir(d)) {
        const char* n = e->d_name;
        if (std::strncmp(n, "card", 4) != 0) continue;
        const char* p = n + 4;
        if (*p == '\0') continue;
        bool digits = true;
        for (const char* q = p; *q != '\0'; ++q) {
            if (*q < '0' || *q > '9') {
                digits = false;
                break;
            }
        }
        if (digits) out.push_back(n);  // 只要 card<数字>，跳过连接器
    }
    closedir(d);
    std::sort(out.begin(), out.end());
    return out;
}

const char* vendorName(const std::string& vendor) {
    if (vendor == "8086") return "Intel";
    if (vendor == "1002") return "AMD";
    if (vendor == "10de") return "NVIDIA";
    if (vendor == "1af4") return "virtio";
    if (vendor == "1b36") return "QXL";
    if (vendor == "1234") return "Bochs";
    return nullptr;
}

// amdgpu 的 pp_dpm_sclk：形如 "0: 500Mhz\n1: 1200Mhz *\n"，取带 * 的那行。
bool amdgpuClock(const std::string& path, long long* out) {
    FILE* f = std::fopen(path.c_str(), "r");
    if (f == nullptr) return false;
    char line[256];
    long long mhz = -1;
    while (std::fgets(line, sizeof(line), f) != nullptr) {
        if (std::strchr(line, '*') == nullptr) continue;
        const char* p = std::strchr(line, ':');
        if (p != nullptr) mhz = std::strtoll(p + 1, nullptr, 10);
    }
    std::fclose(f);
    if (mhz < 0) return false;
    *out = mhz;
    return true;
}

}  // namespace

int32_t gpus(AplGpuInfo* out, uint32_t max, uint32_t* count) {
    if (out == nullptr || count == nullptr) return ERR_STATE;
    *count = 0;

    const std::vector<std::string> cards = drmCards();
    if (cards.empty()) return ERR_UNSUPPORTED;

    std::lock_guard<std::mutex> lock(g_gpu_mtx);
    g_gpu_names.clear();
    g_gpu_drivers.clear();
    g_gpu_pci.clear();
    g_gpu_names.reserve(cards.size());
    g_gpu_drivers.reserve(cards.size());
    g_gpu_pci.reserve(cards.size());

    uint32_t idx = 0;
    for (const std::string& card : cards) {
        if (idx >= max) break;
        const std::string dev = "/sys/class/drm/" + card + "/device";

        // 驱动名：device/driver 是指向模块目录的符号链接。
        std::string driver;
        char link[1024];
        const ssize_t ln = readlink((dev + "/driver").c_str(), link, sizeof(link) - 1);
        if (ln > 0) {
            link[ln] = '\0';
            const char* base = std::strrchr(link, '/');
            driver = base != nullptr ? base + 1 : link;
        }

        // PCI 标识：vendor/device 两个 sysfs 文件。
        std::string pci;
        std::string vendorRaw;
        std::string deviceRaw;
        if (readText(dev + "/vendor", &vendorRaw)) {
            const std::string v = hex4(vendorRaw);
            pci = v;
            if (readText(dev + "/device", &deviceRaw)) pci += ":" + hex4(deviceRaw);
        }
        if (driver.empty() && pci.empty()) continue;

        // 可读名：厂商 + 驱动。
        std::string name;
        const std::string vendorCode = pci.size() >= 4 ? pci.substr(0, 4) : std::string();
        if (const char* vn = vendorName(vendorCode)) name = vn;
        if (!driver.empty()) {
            if (!name.empty()) name += " ";
            name += driver;
        }
        if (name.empty()) name = pci.empty() ? card : pci;

        AplGpuInfo* g = &out[idx];
        *g = AplGpuInfo{};
        g->temperature_millic = -1;
        g->usage_percent = -1;
        g->vram_total_kb = -1;
        g->vram_used_kb = -1;
        g->clock_mhz = -1;

        long long v = 0;
        for (int i = 0; i < 4; ++i) {
            char p[300];
            std::snprintf(p, sizeof(p), "%s/hwmon/hwmon%d/temp1_input", dev.c_str(), i);
            if (readLong(p, &v) && v > 0) {
                g->temperature_millic = static_cast<int32_t>(v);
                break;
            }
        }
        if (readLong(dev + "/gpu_busy_percent", &v)) g->usage_percent = static_cast<int32_t>(v);
        if (readLong(dev + "/mem_info_vram_total", &v)) g->vram_total_kb = v / 1024;
        if (readLong(dev + "/mem_info_vram_used", &v)) g->vram_used_kb = v / 1024;
        if (readLong(dev + "/gt_cur_freq_mhz", &v) ||
            readLong("/sys/class/drm/" + card + "/gt_cur_freq_mhz", &v)) {
            g->clock_mhz = static_cast<int32_t>(v);
        } else if (amdgpuClock(dev + "/pp_dpm_sclk", &v)) {
            g->clock_mhz = static_cast<int32_t>(v);
        }

        g_gpu_names.push_back(name);
        g_gpu_drivers.push_back(driver);
        g_gpu_pci.push_back(pci);

        g->name.data = g_gpu_names.back().c_str();
        g->name.len = g_gpu_names.back().size();
        if (!driver.empty()) {
            g->driver.data = g_gpu_drivers.back().c_str();
            g->driver.len = g_gpu_drivers.back().size();
        }
        if (!pci.empty()) {
            g->pci_id.data = g_gpu_pci.back().c_str();
            g->pci_id.len = g_gpu_pci.back().size();
        }
        ++idx;
    }

    *count = idx;
    return idx > 0 ? OK : ERR_UNSUPPORTED;
}

}  // namespace sysinfo
}  // namespace archoera

#endif  // __linux__
