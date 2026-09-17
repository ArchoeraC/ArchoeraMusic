//! systemd-logind D-Bus 控制面。
//!
//! 一切系统级动作（关机 / 重启 / 背光 / 防休眠）都经 logind，**以普通用户身份**完成：
//! 合成器运行在本地活动会话中，logind 会放行该会话的电源与背光请求，无需 root、
//! 无需 polkit 交互、不写任何特权路径。logind 不可用时（如容器 / WSL）返回 `None`，
//! 控制面自动降级为只读能力。

use std::process;

use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::{OwnedFd, OwnedObjectPath};

/// logind 会话代理句柄。
#[derive(Clone, Debug)]
pub struct Logind {
    conn: Connection,
}

impl Logind {
    /// 连接系统总线。失败（无 D-Bus / 无 logind）返回 `None`。
    pub fn connect() -> Option<Self> {
        match Connection::system() {
            Ok(conn) => Some(Self { conn }),
            Err(err) => {
                tracing::info!(%err, "logind 不可用，系统控制面降级");
                None
            }
        }
    }

    fn manager(&self) -> anyhow::Result<Proxy<'_>> {
        Ok(Proxy::new(
            &self.conn,
            "org.freedesktop.login1",
            "/org/freedesktop/login1",
            "org.freedesktop.login1.Manager",
        )?)
    }

    fn session<'a>(&'a self, path: &'a OwnedObjectPath) -> anyhow::Result<Proxy<'a>> {
        Ok(Proxy::new(
            &self.conn,
            "org.freedesktop.login1",
            path.as_str(),
            "org.freedesktop.login1.Session",
        )?)
    }

    /// 关机。`interactive=true` 允许 logind 触发 polkit 交互（kiosk 下无 agent，故先试 `false`）。
    pub fn power_off(&self, interactive: bool) -> anyhow::Result<()> {
        self.manager()?
            .call::<_, _, ()>("PowerOff", &(interactive,))?;
        Ok(())
    }

    /// 重启。
    pub fn reboot(&self, interactive: bool) -> anyhow::Result<()> {
        self.manager()?
            .call::<_, _, ()>("Reboot", &(interactive,))?;
        Ok(())
    }

    /// 设置背光。`subsystem` 固定为 `"backlight"`，`name` 为 `/sys/class/backlight` 下的设备名。
    pub fn set_brightness(&self, name: &str, value: u32) -> anyhow::Result<()> {
        let manager = self.manager()?;
        let path: OwnedObjectPath =
            manager.call::<_, _, OwnedObjectPath>("GetSessionByPID", &(process::id(),))?;
        self.session(&path)?
            .call::<_, _, ()>("SetBrightness", &("backlight", name, value))?;
        Ok(())
    }

    /// 申请防休眠 `lock`（返回的 fd 必须保持打开，关闭即释放）。
    pub fn inhibit_idle(&self, reason: &str) -> anyhow::Result<OwnedFd> {
        let fd: OwnedFd = self
            .manager()?
            .call("Inhibit", &("idle", "archoera-shell", reason, "block"))?;
        Ok(fd)
    }
}
