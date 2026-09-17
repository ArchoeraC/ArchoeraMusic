//! `zwp_linux_dmabuf_v1` 处理器。
//!
//! Flutter / GTK 的 Linux 嵌入层默认用 EGL + dmabuf 提交画面（避免 `wl_shm`
//! 的整帧拷贝）。合成器只要把全局对象注册出去，并在 `dmabuf_imported` 里
//! **同步**把缓冲导入渲染器，客户端即可用 GPU 路径渲染。
//!
//! 若渲染器不支持任何 dmabuf 格式（如软件渲染），全局不会被注册，客户端会
//! 自动回退到 `wl_shm`（见 `ArchoeraShell::setup_dmabuf`）。

use smithay::{
    backend::{
        allocator::{dmabuf::Dmabuf, Buffer},
        renderer::ImportDma,
    },
    wayland::dmabuf::{DmabufGlobal, DmabufHandler, DmabufState, ImportNotifier},
};

use crate::state::ArchoeraShell;

impl DmabufHandler for ArchoeraShell {
    fn dmabuf_state(&mut self) -> &mut DmabufState {
        &mut self.dmabuf_state
    }

    fn dmabuf_imported(
        &mut self,
        _global: &DmabufGlobal,
        dmabuf: Dmabuf,
        notifier: ImportNotifier,
    ) {
        let Some(backend) = self.backend.as_mut() else {
            // 后端尚未初始化（理论上不会发生：全局在 init 后才注册）。
            notifier.failed();
            return;
        };

        tracing::trace!(
            y_inverted = dmabuf.y_inverted(),
            format = ?dmabuf.format(),
            modifier = ?dmabuf.format().modifier,
            size = ?dmabuf.size(),
            "导入客户端 dmabuf"
        );

        match backend.renderer().import_dmabuf(&dmabuf, None) {
            Ok(_) => {
                if let Err(err) = notifier.successful::<Self>() {
                    tracing::warn!(%err, "dmabuf 已导入渲染器，但创建 wl_buffer 失败");
                }
            }
            Err(err) => {
                tracing::warn!(%err, "dmabuf 导入渲染器失败");
                notifier.failed();
            }
        }
    }
}

smithay::delegate_dmabuf!(ArchoeraShell);
