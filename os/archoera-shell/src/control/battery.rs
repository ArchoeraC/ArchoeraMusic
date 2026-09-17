//! 电池状态：读取 `/sys/class/power_supply`。
//!
//! 无电池设备（台式机 / 多数虚拟机 / WSL）返回 `present = false`，合成器据此
//! 不下发 battery 事件、也不置位 `capability.battery`。

use std::fs;
use std::path::PathBuf;

/// 一次电池采样。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BatteryState {
    pub present: bool,
    pub percent: u32,
    pub charging: bool,
}

impl BatteryState {
    pub const ABSENT: Self = Self {
        present: false,
        percent: 0,
        charging: false,
    };
}

/// 已发现的电池设备。
#[derive(Debug, Clone)]
pub struct Battery {
    dir: PathBuf,
}

impl Battery {
    /// 扫描 `/sys/class/power_supply`，找 `type == "Battery"` 且存在 `capacity` 的设备。
    pub fn discover() -> Option<Self> {
        let entries = fs::read_dir("/sys/class/power_supply").ok()?;
        for entry in entries.flatten() {
            let dir = entry.path();
            let kind = fs::read_to_string(dir.join("type")).unwrap_or_default();
            if kind.trim() != "Battery" {
                continue;
            }
            if !dir.join("capacity").exists() {
                continue;
            }
            return Some(Self { dir });
        }
        None
    }

    pub fn is_present(&self) -> bool {
        true
    }

    /// 采样一次；读取失败视为缺失。
    pub fn read(&self) -> BatteryState {
        let percent = fs::read_to_string(self.dir.join("capacity"))
            .ok()
            .and_then(|s| s.trim().parse::<u32>().ok())
            .unwrap_or(0)
            .min(100);
        let status = fs::read_to_string(self.dir.join("status")).unwrap_or_default();
        let status = status.trim();
        let charging = matches!(status, "Charging" | "Full" | "Not charging");
        BatteryState {
            present: true,
            percent,
            charging,
        }
    }
}
