//! 背光控制：sysfs 为主、logind 兜底。
//!
//! 读取走 `/sys/class/backlight/<dev>/{max_brightness,brightness}`（普通用户可读）；
//! 写入先试 sysfs（部分设备对 `video` 组开放），失败再经 logind `Session.SetBrightness`
//! 交由会话权限完成——两条路径都不需要 root。

use std::fs;
use std::path::PathBuf;

use super::Logind;

/// 已发现的背光设备。
#[derive(Debug, Clone)]
pub struct Backlight {
    name: String,
    dir: PathBuf,
    max: u32,
}

impl Backlight {
    /// 扫描 `/sys/class/backlight`，取第一个 `max_brightness > 0` 的设备。
    pub fn discover() -> Option<Self> {
        let entries = fs::read_dir("/sys/class/backlight").ok()?;
        let mut fallback: Option<Self> = None;

        for entry in entries.flatten() {
            let dir = entry.path();
            let max = read_u32(&dir.join("max_brightness")).unwrap_or(0);
            if max == 0 {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            let device = Self { name, dir, max };
            // 优先面板直连背光，避免误选键盘/外设背光。
            if device.name.contains("backlight") || device.name.contains("panel") {
                return Some(device);
            }
            if fallback.is_none() {
                fallback = Some(device);
            }
        }
        fallback
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// 当前亮度百分比（0-100）。
    pub fn percent(&self) -> Option<u32> {
        let raw = read_u32(&self.dir.join("brightness"))?;
        Some(raw.saturating_mul(100) / self.max.max(1))
    }

    /// 设置亮度百分比（0-100，越界夹取）；返回落地后的百分比。
    ///
    /// 先写 sysfs，失败则回报由调用方走 logind。成功返回 `Ok(percent)`。
    pub fn set_sysfs(&self, percent: u32) -> anyhow::Result<u32> {
        let percent = percent.min(100);
        // 保留 1 作为下限，避免误把面板完全熄灭。
        let raw = ((percent as u64 * self.max as u64 / 100).max(1)).min(self.max as u64) as u32;
        fs::write(self.dir.join("brightness"), raw.to_string())?;
        Ok(percent)
    }

    /// 由调用方在 sysfs 失败后调用：把百分比换算为该设备的原始值。
    pub fn raw_for(&self, percent: u32) -> u32 {
        let percent = percent.min(100);
        ((percent as u64 * self.max as u64 / 100).max(1)).min(self.max as u64) as u32
    }
}

fn read_u32(path: &PathBuf) -> Option<u32> {
    fs::read_to_string(path).ok()?.trim().parse::<u32>().ok()
}

/// 综合写入：先 sysfs，再 logind。`logind` 为空时仅尝试 sysfs。
pub fn apply(device: &Backlight, logind: Option<&Logind>, percent: u32) -> Option<u32> {
    let percent = percent.min(100);
    if device.set_sysfs(percent).is_ok() {
        return Some(percent);
    }
    let logind = logind?;
    match logind.set_brightness(device.name(), device.raw_for(percent)) {
        Ok(()) => Some(percent),
        Err(err) => {
            tracing::warn!(%err, device = device.name(), "设置亮度失败");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(max: u32) -> Backlight {
        Backlight {
            name: "test_backlight".to_string(),
            dir: PathBuf::from("/nonexistent"),
            max,
        }
    }

    #[test]
    fn raw_value_keeps_a_minimum_of_one() {
        let dev = device(255);
        assert_eq!(dev.raw_for(0), 1);
        assert_eq!(dev.raw_for(1), 2); // 1 * 255 / 100 = 2（整数截断）
        assert_eq!(dev.raw_for(50), 127);
        assert_eq!(dev.raw_for(100), 255);
    }

    #[test]
    fn raw_value_clamps_over_range_input() {
        let dev = device(1000);
        assert_eq!(dev.raw_for(1000), 1000);
    }
}
