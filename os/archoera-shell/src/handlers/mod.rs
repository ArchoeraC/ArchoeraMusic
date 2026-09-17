//! Wayland 前端协议处理器。
//!
//! 每个协议一种职责：`compositor` / `shm` / `buffer`、`xdg_shell`（含 xdg-decoration）、
//! `dmabuf`（Flutter/GTK 的 EGL 路径）、`archoera_shell`（自定义控制协议）。
//! `Seat` / `DataDevice` / `Output` / `IdleInhibit` 这类跨协议状态在本模块统一实现。

mod archoera_shell;
mod compositor;
mod dmabuf;
mod xdg_shell;

use smithay::{
    delegate_data_device, delegate_fractional_scale, delegate_idle_inhibit, delegate_output,
    delegate_seat,
    input::{Seat, SeatHandler, SeatState},
    reexports::wayland_server::{protocol::wl_surface::WlSurface, Resource},
    wayland::{
        compositor::with_states,
        fractional_scale::{self, FractionalScaleHandler},
        idle_inhibit::IdleInhibitHandler,
        output::OutputHandler,
        selection::{
            data_device::{
                set_data_device_focus, ClientDndGrabHandler, DataDeviceHandler, DataDeviceState,
                ServerDndGrabHandler,
            },
            SelectionHandler,
        },
    },
};

use crate::state::ArchoeraShell;

//
// wl_seat
//

impl SeatHandler for ArchoeraShell {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self.seat_state
    }

    fn cursor_image(
        &mut self,
        _seat: &Seat<Self>,
        _image: smithay::input::pointer::CursorImageStatus,
    ) {
        // kiosk 默认使用隐藏光标；播放器如需自定义光标可在此承接。
    }

    fn focus_changed(&mut self, seat: &Seat<Self>, focused: Option<&WlSurface>) {
        let dh = &self.display_handle;
        let client = focused.and_then(|s| dh.get_client(s.id()).ok());
        set_data_device_focus(dh, seat, client);
    }
}

delegate_seat!(ArchoeraShell);

//
// wl_data_device（剪贴板 / 拖放）
//

impl SelectionHandler for ArchoeraShell {
    type SelectionUserData = ();
}

impl DataDeviceHandler for ArchoeraShell {
    fn data_device_state(&self) -> &DataDeviceState {
        &self.data_device_state
    }
}

impl ClientDndGrabHandler for ArchoeraShell {}
impl ServerDndGrabHandler for ArchoeraShell {}

delegate_data_device!(ArchoeraShell);

//
// wl_output / zxdg_output
//

impl OutputHandler for ArchoeraShell {}

delegate_output!(ArchoeraShell);

//
// zwp_idle_inhibit（播放器请求防休眠）
//

impl IdleInhibitHandler for ArchoeraShell {
    fn inhibit(&mut self, surface: WlSurface) {
        self.idle_inhibitors = self.idle_inhibitors.saturating_add(1);
        if self.idle_inhibitors == 1 {
            let reason = self
                .idle_reason
                .clone()
                .unwrap_or_else(|| "播放器请求保持唤醒".to_string());
            if self.control.set_idle_inhibited(true, &reason) {
                tracing::info!(?surface, "已开启防休眠");
            }
        }
    }

    fn uninhibit(&mut self, surface: WlSurface) {
        self.idle_inhibitors = self.idle_inhibitors.saturating_sub(1);
        if self.idle_inhibitors == 0 {
            self.control.set_idle_inhibited(false, "");
            tracing::info!(?surface, "已关闭防休眠");
        }
    }
}

delegate_idle_inhibit!(ArchoeraShell);

//
// wp_fractional_scale_v1（客户端按输出分数缩放清晰渲染）
//

impl FractionalScaleHandler for ArchoeraShell {
    fn new_fractional_scale(&mut self, surface: WlSurface) {
        // 输出缩放由 `--scale` 决定；新 surface 订阅时即告知首选分数缩放，
        // 客户端（GTK/Flutter）据此按物理像素渲染，避免模糊。
        let scale = self.config.scale;
        with_states(&surface, |states| {
            fractional_scale::with_fractional_scale(states, |fs| fs.set_preferred_scale(scale));
        });
    }
}

delegate_fractional_scale!(ArchoeraShell);
