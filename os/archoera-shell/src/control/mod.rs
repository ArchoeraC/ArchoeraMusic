//! 控制面：把 `archoera_shell_v1` 的请求落到真实系统，并汇总能力位。
//!
//! 分层：本模块只做「策略 + 状态」，具体机制在子模块：
//! - [`logind`] —— D-Bus 会话动作（关机 / 重启 / 背光 / 防休眠）
//! - [`brightness`] —— `/sys/class/backlight` 读写与 logind 兜底
//! - [`battery`] —— `/sys/class/power_supply` 采样

pub mod battery;
pub mod brightness;
pub mod logind;

use zbus::zvariant::OwnedFd;

use crate::protocol::Capability;

pub use battery::BatteryState;
pub use logind::Logind;

/// 会话控制面。
#[derive(Debug)]
pub struct ControlPlane {
    logind: Option<Logind>,
    backlight: Option<brightness::Backlight>,
    battery: Option<battery::Battery>,
    capabilities: Capability,
    volume: u32,
    /// 防休眠抑制 fd：持有即生效，丢弃即释放。
    idle_inhibit: Option<OwnedFd>,
    /// 屏幕开关（DPMS）是否受支持：仅 udev 裸机后端可置位。
    screen_supported: bool,
    screen_enabled: bool,
}

impl ControlPlane {
    pub fn new(volume: u32) -> Self {
        let logind = Logind::connect();
        let backlight = brightness::Backlight::discover();
        let battery = battery::Battery::discover();

        let mut capabilities = Capability::empty();
        if backlight.is_some() {
            capabilities |= Capability::Brightness;
        }
        if logind.is_some() {
            capabilities |= Capability::Power;
        }
        // 挂起/休眠：logind 明确报告可用时才置位（普通用户即可）。
        if let Some(logind) = &logind {
            if logind.can_suspend() || logind.can_hibernate() {
                capabilities |= Capability::Suspend;
            }
        }
        // 音量由播放器落实，合成器只做状态镜像与事件广播，故始终置位。
        capabilities |= Capability::Volume | Capability::MediaKeys;
        // 电源键 / 睡眠键由输入后端映射后广播，始终置位。
        capabilities |= Capability::PowerKey;
        if battery.is_some() {
            capabilities |= Capability::Battery;
        }

        Self {
            logind,
            backlight,
            battery,
            capabilities,
            volume: volume.min(100),
            idle_inhibit: None,
            screen_supported: false,
            screen_enabled: true,
        }
    }

    pub fn capabilities(&self) -> Capability {
        self.capabilities
    }

    pub fn volume(&self) -> u32 {
        self.volume
    }

    pub fn set_volume(&mut self, percent: u32) {
        self.volume = percent.min(100);
    }

    pub fn brightness_percent(&self) -> Option<u32> {
        self.backlight.as_ref()?.percent()
    }

    /// 设置亮度；返回落地百分比（无背光设备返回 `None`）。
    pub fn set_brightness(&mut self, percent: u32) -> Option<u32> {
        let device = self.backlight.as_ref()?;
        brightness::apply(device, self.logind.as_ref(), percent)
    }

    pub fn power_off(&self) -> anyhow::Result<()> {
        let logind = self
            .logind
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("logind 不可用，无法关机"))?;
        logind
            .power_off(false)
            .or_else(|_| logind.power_off(true))
            .map_err(|e| anyhow::anyhow!("关机失败: {e}"))
    }

    pub fn reboot(&self) -> anyhow::Result<()> {
        let logind = self
            .logind
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("logind 不可用，无法重启"))?;
        logind
            .reboot(false)
            .or_else(|_| logind.reboot(true))
            .map_err(|e| anyhow::anyhow!("重启失败: {e}"))
    }

    pub fn suspend(&self) -> anyhow::Result<()> {
        let logind = self
            .logind
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("logind 不可用，无法挂起"))?;
        logind
            .suspend(false)
            .or_else(|_| logind.suspend(true))
            .map_err(|e| anyhow::anyhow!("挂起失败: {e}"))
    }

    pub fn hibernate(&self) -> anyhow::Result<()> {
        let logind = self
            .logind
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("logind 不可用，无法休眠"))?;
        logind
            .hibernate(false)
            .or_else(|_| logind.hibernate(true))
            .map_err(|e| anyhow::anyhow!("休眠失败: {e}"))
    }

    /// 标记屏幕开关能力（由 udev 后端初始化时置位）。
    pub fn set_screen_supported(&mut self, supported: bool) {
        self.screen_supported = supported;
        if supported {
            self.capabilities |= Capability::Screen;
        } else {
            self.capabilities.remove(Capability::Screen);
        }
    }

    pub fn screen_supported(&self) -> bool {
        self.screen_supported
    }

    /// 标记输出显示设置能力（模式/缩放/旋转；由 udev 后端初始化时置位）。
    pub fn set_output_supported(&mut self, supported: bool) {
        if supported {
            self.capabilities |= Capability::Output;
        } else {
            self.capabilities.remove(Capability::Output);
        }
    }

    pub fn screen_enabled(&self) -> bool {
        self.screen_enabled
    }

    /// 记录屏幕开关状态（实际 DPMS 动作由后端落实）。
    pub fn set_screen_enabled(&mut self, enabled: bool) {
        self.screen_enabled = enabled;
    }

    pub fn battery_state(&self) -> BatteryState {
        match &self.battery {
            Some(b) if b.is_present() => b.read(),
            _ => BatteryState::ABSENT,
        }
    }

    /// 开关防休眠；返回实际生效状态。
    pub fn set_idle_inhibited(&mut self, inhibit: bool, reason: &str) -> bool {
        if inhibit {
            if self.idle_inhibit.is_some() {
                return true;
            }
            let Some(logind) = &self.logind else {
                tracing::warn!("logind 不可用，防休眠请求忽略");
                return false;
            };
            match logind.inhibit_idle(reason) {
                Ok(fd) => {
                    self.idle_inhibit = Some(fd);
                    true
                }
                Err(err) => {
                    tracing::warn!(%err, "申请防休眠失败");
                    false
                }
            }
        } else {
            self.idle_inhibit = None;
            false
        }
    }
}
